/**
 * Server Entrypoint for aws-cicd-demo
 * Manages HTTP server lifecycle, graceful shutdown on SIGTERM/SIGINT,
 * and unhandled process exceptions.
 */

const app = require('./app');
const logger = require('./logger');

const PORT = parseInt(process.env.PORT, 10) || 3000;
const HOST = process.env.HOST || '0.0.0.0';

const server = app.listen(PORT, HOST, () => {
  logger.info(`Server started successfully`, {
    host: HOST,
    port: PORT,
    environment: process.env.NODE_ENV || 'development',
    version: process.env.APP_VERSION || '1.0.0',
    pid: process.pid
  });
});

// Track active connections for graceful shutdown
const connections = new Set();
server.on('connection', connection => {
  connections.add(connection);
  connection.on('close', () => connections.delete(connection));
});

let isShuttingDown = false;

function gracefulShutdown(signal) {
  if (isShuttingDown) return;
  isShuttingDown = true;

  logger.info(`Received ${signal}. Initiating graceful shutdown...`);

  // Stop accepting new incoming requests
  server.close(err => {
    if (err) {
      logger.error('Error closing HTTP server during shutdown', { error: err.message });
      process.exit(1);
    }
    logger.info('HTTP server closed. Exiting process.');
    process.exit(0);
  });

  // Enforce termination after timeout if connections hang
  const SHUTDOWN_TIMEOUT_MS = 10000;
  const timeoutTimer = setTimeout(() => {
    logger.warn(`Graceful shutdown timed out after ${SHUTDOWN_TIMEOUT_MS / 1000}s. Forcing exit.`);
    connections.forEach(conn => conn.destroy());
    process.exit(1);
  }, SHUTDOWN_TIMEOUT_MS);

  if (typeof timeoutTimer.unref === 'function') {
    timeoutTimer.unref();
  }
}

// Process signal listeners for container orchestration (Docker / Kubernetes / EC2 systemd)
process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));

process.on('uncaughtException', err => {
  logger.error('Uncaught Exception thrown', {
    error: err.message,
    stack: err.stack
  });
  process.exit(1);
});

process.on('unhandledRejection', (reason, promise) => {
  logger.error('Unhandled Promise Rejection', {
    reason: reason instanceof Error ? reason.message : String(reason),
    stack: reason instanceof Error ? reason.stack : undefined
  });
});

module.exports = server;
