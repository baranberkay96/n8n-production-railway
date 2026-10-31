'use strict';
/*
 * n8n Worker supervisor for Railway: runs the n8n queue worker and the n8n task runner
 * launcher (JavaScript + Python Code nodes) in one container, so every Railway replica
 * of this service is a complete worker.
 *
 * - n8n worker: user "node", the service environment, task broker on 127.0.0.1 only.
 * - task-runner-launcher: user "runner", a minimal environment (runner settings and the
 *   runner auth token, no database/Redis credentials and no encryption key), so Code
 *   nodes cannot read the worker's secrets.
 * - The launcher is restarted with backoff if it exits. If the worker exits, the
 *   launcher is stopped and the container exits with the worker's status.
 * - SIGTERM/SIGINT: the worker drains first (N8N_GRACEFUL_SHUTDOWN_TIMEOUT), then the
 *   launcher stops, so running executions keep their runners until they finish.
 *
 *   node worker-supervisor.cjs              run (container entrypoint)
 *   node worker-supervisor.cjs --self-test  validate the runner config (Docker build)
 */
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');

const DEFAULTS = Object.freeze({
  workerCommand: '/docker-entrypoint.sh',
  workerArgs: ['worker'],
  launcherCommand: '/usr/local/bin/task-runner-launcher',
  launcherArgs: ['javascript', 'python'],
  baseConfigPath: '/etc/n8n-task-runners.json',
  renderedConfigPath: '/tmp/n8n-task-runners.json',
  workerUser: 'node',
  runnerUser: 'runner',
  workerHome: '/home/node',
  runnerHome: '/home/runner',
  launcherStopTimeoutMs: 20_000,
  restartDelayMinMs: 2_000,
  restartDelayMaxMs: 30_000,
  stableRunMs: 60_000,
});

// Optional allow-list overrides (empty = the official runners image defaults).
const ALLOWLIST_OVERRIDES = Object.freeze([
  { variable: 'CODE_JS_ALLOW_BUILTIN', runnerType: 'javascript', key: 'NODE_FUNCTION_ALLOW_BUILTIN' },
  { variable: 'CODE_PY_STDLIB_ALLOW', runnerType: 'python', key: 'N8N_RUNNERS_STDLIB_ALLOW' },
]);
const ALLOWLIST_PATTERN = /^(\*|[A-Za-z_][A-Za-z0-9_.]*(,[A-Za-z_][A-Za-z0-9_.]*)*)$/;

// What the launcher may see: runner settings only (it filters again per runner type).
const LAUNCHER_ENV_PREFIX = 'N8N_RUNNERS_';
const LAUNCHER_ENV_NAMES = Object.freeze(['PATH', 'GENERIC_TIMEZONE', 'TZ', 'LANG']);
const SUPERVISOR_ONLY_VARIABLES = Object.freeze(ALLOWLIST_OVERRIDES.map((o) => o.variable));

const SIGNAL_NUMBERS = Object.freeze({ SIGINT: 2, SIGKILL: 9, SIGTERM: 15 });

function log(message) {
  process.stdout.write(`[n8n-worker] ${message}\n`);
}

function brokerPort(env) {
  const port = Number(env.N8N_RUNNERS_BROKER_PORT || '5679');
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`N8N_RUNNERS_BROKER_PORT must be a port number (got '${env.N8N_RUNNERS_BROKER_PORT}')`);
  }
  return port;
}

function validateEnv(env) {
  if (!env.N8N_RUNNERS_AUTH_TOKEN) {
    throw new Error('N8N_RUNNERS_AUTH_TOKEN is empty; it authenticates the task runners with the worker');
  }
  brokerPort(env);
  for (const { variable } of ALLOWLIST_OVERRIDES) {
    const value = normalizeAllowlist(env[variable]);
    if (value !== '' && !ALLOWLIST_PATTERN.test(value)) {
      throw new Error(`${variable} must be '*' or comma-separated module names (got '${env[variable]}')`);
    }
  }
}

function normalizeAllowlist(value) {
  return typeof value === 'string' ? value.replace(/\s+/g, '') : '';
}

/** Returns a copy of the official runner config with the requested allow-list overrides. */
function renderRunnerConfig(baseConfig, env) {
  const runners = baseConfig && baseConfig['task-runners'];
  if (!Array.isArray(runners) || runners.length === 0) {
    throw new Error('runner config has no "task-runners" entries');
  }
  const types = runners.map((runner) => runner['runner-type']);
  for (const required of DEFAULTS.launcherArgs) {
    if (!types.includes(required)) throw new Error(`runner config has no "${required}" runner`);
  }
  const applied = [];
  const rendered = runners.map((runner) => {
    const overrides = ALLOWLIST_OVERRIDES.filter(
      (o) => o.runnerType === runner['runner-type'] && normalizeAllowlist(env[o.variable]) !== '',
    );
    if (overrides.length === 0) return { ...runner };
    const extra = Object.fromEntries(overrides.map((o) => [o.key, normalizeAllowlist(env[o.variable])]));
    applied.push(...overrides.map((o) => `${o.key}=${extra[o.key]} (${o.runnerType})`));
    return { ...runner, 'env-overrides': { ...(runner['env-overrides'] || {}), ...extra } };
  });
  return { config: { ...baseConfig, 'task-runners': rendered }, applied };
}

function writeRunnerConfig(options, env) {
  const base = JSON.parse(fs.readFileSync(options.baseConfigPath, 'utf8'));
  const { config, applied } = renderRunnerConfig(base, env);
  fs.writeFileSync(options.renderedConfigPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o644 });
  fs.chmodSync(options.renderedConfigPath, 0o644);
  return applied;
}

function workerEnv(env, options) {
  const result = Object.fromEntries(
    Object.entries(env).filter(([name]) => !SUPERVISOR_ONLY_VARIABLES.includes(name)),
  );
  return {
    ...result,
    HOME: options.workerHome,
    N8N_RUNNERS_MODE: 'external',
    N8N_RUNNERS_BROKER_LISTEN_ADDRESS: '127.0.0.1',
    N8N_RUNNERS_BROKER_PORT: String(brokerPort(env)),
  };
}

function launcherEnv(env, options) {
  const selected = Object.fromEntries(
    Object.entries(env).filter(
      ([name]) => name.startsWith(LAUNCHER_ENV_PREFIX) || LAUNCHER_ENV_NAMES.includes(name),
    ),
  );
  return {
    ...selected,
    HOME: options.runnerHome,
    N8N_RUNNERS_TASK_BROKER_URI: `http://127.0.0.1:${brokerPort(env)}`,
    N8N_RUNNERS_CONFIG_PATH: options.renderedConfigPath,
  };
}

/** uid/gid of a local user from /etc/passwd, or null when unknown. */
function lookupUser(name, passwdPath = '/etc/passwd') {
  try {
    const line = fs
      .readFileSync(passwdPath, 'utf8')
      .split('\n')
      .find((entry) => entry.split(':')[0] === name);
    if (!line) return null;
    const [, , uid, gid] = line.split(':');
    return { uid: Number(uid), gid: Number(gid) };
  } catch {
    return null;
  }
}

function identities(options) {
  if (typeof process.getuid !== 'function' || process.getuid() !== 0) {
    log(`not running as root: worker and runners share user ${os.userInfo().username}`);
    return { worker: {}, runner: {} };
  }
  const worker = lookupUser(options.workerUser);
  const runner = lookupUser(options.runnerUser);
  if (!worker || !runner) {
    throw new Error(`users '${options.workerUser}' and '${options.runnerUser}' must exist in /etc/passwd`);
  }
  return { worker, runner };
}

function exitCodeOf(code, signal) {
  if (typeof code === 'number') return code;
  return 128 + (SIGNAL_NUMBERS[signal] || 1);
}

function describeExit(code, signal) {
  return signal ? `signal ${signal}` : `code ${code}`;
}

/** Starts the worker and the launcher; resolves with the exit code for the container. */
function run(options, env) {
  return new Promise((resolve) => {
    validateEnv(env);
    const applied = writeRunnerConfig(options, env);
    applied.forEach((entry) => log(`runner allow-list override: ${entry}`));
    const ids = identities(options);

    const state = { worker: null, launcher: null, stopping: false, restartTimer: null, restartDelay: options.restartDelayMinMs };

    function finish(code) {
      clearTimeout(state.restartTimer);
      stopLauncher().then(() => resolve(code));
    }

    function stopLauncher() {
      clearTimeout(state.restartTimer);
      const child = state.launcher;
      if (!child) return Promise.resolve();
      return new Promise((done) => {
        const killTimer = setTimeout(() => {
          log('task runner launcher did not stop in time; killing it');
          child.kill('SIGKILL');
        }, options.launcherStopTimeoutMs);
        child.once('exit', () => {
          clearTimeout(killTimer);
          done();
        });
        child.kill('SIGTERM');
      });
    }

    function startLauncher() {
      if (state.stopping) return;
      const startedAt = Date.now();
      let handled = false;
      const child = spawn(options.launcherCommand, options.launcherArgs, {
        env: launcherEnv(env, options),
        cwd: options.runnerHome,
        stdio: 'inherit',
        ...ids.runner,
      });
      state.launcher = child;
      const onEnd = (reason) => {
        if (handled) return;
        handled = true;
        if (state.launcher === child) state.launcher = null;
        if (state.stopping) return;
        // Restart quickly after a long run; back off (doubling, capped) while it keeps failing.
        const delay = Date.now() - startedAt >= options.stableRunMs ? options.restartDelayMinMs : state.restartDelay;
        state.restartDelay = Math.min(delay * 2, options.restartDelayMaxMs);
        log(`task runner launcher stopped (${reason}); restarting in ${delay / 1000}s`);
        state.restartTimer = setTimeout(startLauncher, delay);
      };
      child.once('error', (error) => onEnd(`error: ${error.message}`));
      child.once('exit', (code, signal) => onEnd(describeExit(code, signal)));
    }

    function startWorker() {
      const child = spawn(options.workerCommand, options.workerArgs, {
        env: workerEnv(env, options),
        cwd: options.workerHome,
        stdio: 'inherit',
        ...ids.worker,
      });
      state.worker = child;
      let handled = false;
      const onEnd = (code, reason) => {
        if (handled) return;
        handled = true;
        state.worker = null;
        if (!state.stopping) log(`n8n worker exited unexpectedly (${reason}); stopping the task runners`);
        state.stopping = true;
        finish(code);
      };
      child.once('error', (error) => onEnd(1, `error: ${error.message}`));
      child.once('exit', (code, signal) => onEnd(exitCodeOf(code, signal), describeExit(code, signal)));
    }

    function onSignal(signal) {
      if (state.stopping) return;
      state.stopping = true;
      clearTimeout(state.restartTimer);
      log(`${signal} received: draining the n8n worker, then stopping the task runners`);
      if (state.worker) state.worker.kill('SIGTERM');
      else finish(exitCodeOf(null, signal));
    }

    process.on('SIGTERM', () => onSignal('SIGTERM'));
    process.on('SIGINT', () => onSignal('SIGINT'));

    log(`starting n8n worker and task runners (broker 127.0.0.1:${brokerPort(env)})`);
    startWorker();
    startLauncher();
  });
}

function selfTest(options, env) {
  validateEnv({ ...env, N8N_RUNNERS_AUTH_TOKEN: env.N8N_RUNNERS_AUTH_TOKEN || 'self-test' });
  const base = JSON.parse(fs.readFileSync(options.baseConfigPath, 'utf8'));
  const { config } = renderRunnerConfig(base, env);
  for (const runner of config['task-runners']) {
    fs.accessSync(runner.command, fs.constants.X_OK);
  }
  fs.accessSync(options.launcherCommand, fs.constants.X_OK);
  if (!lookupUser(options.workerUser) || !lookupUser(options.runnerUser)) {
    throw new Error(`users '${options.workerUser}' and '${options.runnerUser}' must exist`);
  }
  log(`self-test ok: runners ${config['task-runners'].map((r) => r['runner-type']).join(', ')}`);
}

module.exports = {
  DEFAULTS,
  exitCodeOf,
  launcherEnv,
  lookupUser,
  renderRunnerConfig,
  run,
  validateEnv,
  workerEnv,
};

function fail(error) {
  process.stderr.write(`[n8n-worker] ERROR: ${error.message}\n`);
  process.exit(1);
}

if (require.main === module) {
  const options = { ...DEFAULTS };
  if (process.argv.includes('--self-test')) {
    try {
      selfTest(options, process.env);
    } catch (error) {
      fail(error);
    }
  } else {
    run(options, process.env).then((code) => process.exit(code), fail);
  }
}
