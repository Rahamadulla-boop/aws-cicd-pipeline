/**
 * Express Application Definition for aws-cicd-demo
 */

const express = require('express');
const path = require('path');
const logger = require('./logger');

const app = express();

// Application Metadata Helpers from Environment
const getAppName = () => process.env.APP_NAME || 'aws-cicd-demo';
const getAppVersion = () => process.env.APP_VERSION || '1.0.0';
const getNodeEnv = () => process.env.NODE_ENV || 'development';
const getCommitSha = () => process.env.COMMIT_SHA || 'local-dev';
const getBuildTimestamp = () => process.env.BUILD_TIMESTAMP || new Date().toISOString();
const getDeploymentTimestamp = () => process.env.DEPLOYMENT_TIMESTAMP || getBuildTimestamp();

// Disable Express fingerprinting
app.disable('x-powered-by');

// Basic security headers middleware
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('X-XSS-Protection', '1; mode=block');
  next();
});

// JSON body parsing
app.use(express.json());

// Request logging middleware
app.use(logger.requestLogger);

// Serve static frontend dashboard assets
app.use(express.static(path.join(__dirname, '../public')));

/**
 * GET /api/health
 * Used by container HEALTHCHECK, AWS deployment verification, and automated rollback logic.
 *
 * Configurable simulated failure:
 * - Disabled by default
 * - Restricted to non-production environments (NODE_ENV !== 'production')
 * - In production, this flag is strictly ignored as a safeguard
 */
app.get('/api/health', (req, res) => {
  const currentEnv = getNodeEnv();
  const currentVersion = getAppVersion();
  const currentAppName = getAppName();
  const isSimulationRequested = process.env.SIMULATE_FAILURE === 'true' || process.env.SIMULATE_FAILURE === '1';

  if (isSimulationRequested) {
    if (currentEnv === 'production') {
      logger.warn('SIMULATE_FAILURE flag was provided in production environment; safeguard prevented failure activation.');
    } else {
      logger.warn('Simulated failure triggered for rollback/health verification testing', {
        environment: currentEnv,
        version: currentVersion
      });
      return res.status(500).json({
        status: 'unhealthy',
        application: currentAppName,
        version: currentVersion,
        environment: currentEnv,
        timestamp: new Date().toISOString(),
        error: 'Simulated failure active for rollback testing'
      });
    }
  }

  return res.status(200).json({
    status: 'healthy',
    application: currentAppName,
    version: currentVersion,
    environment: currentEnv,
    uptimeSeconds: Math.floor(process.uptime()),
    timestamp: new Date().toISOString()
  });
});

/**
 * GET /api/info
 * Returns application deployment metadata and runtime environment stats.
 * Explicitly sanitizes all outputs to prevent credential/secret leakage.
 */
app.get('/api/info', (req, res) => {
  const memoryUsage = process.memoryUsage();

  res.status(200).json({
    application: getAppName(),
    version: getAppVersion(),
    environment: getNodeEnv(),
    commitSha: getCommitSha(),
    buildTimestamp: getBuildTimestamp(),
    deploymentTimestamp: getDeploymentTimestamp(),
    nodeVersion: process.version,
    platform: process.platform,
    arch: process.arch,
    memory: {
      rssMb: Number((memoryUsage.rss / (1024 * 1024)).toFixed(2)),
      heapUsedMb: Number((memoryUsage.heapUsed / (1024 * 1024)).toFixed(2)),
      heapTotalMb: Number((memoryUsage.heapTotal / (1024 * 1024)).toFixed(2))
    },
    uptimeSeconds: Math.floor(process.uptime()),
    timestamp: new Date().toISOString()
  });
});

/**
 * GET /api/ready
 * Readiness probe to confirm initialization and dependency checks.
 */
app.get('/api/ready', (req, res) => {
  res.status(200).json({
    status: 'ready',
    application: getAppName(),
    checks: {
      initialization: 'passed',
      memory: 'passed'
    },
    timestamp: new Date().toISOString()
  });
});

// Explicit root route fallback if static index.html is bypassed
app.get('/', (req, res, next) => {
  if (req.accepts('html')) {
    return res.sendFile(path.join(__dirname, '../public/index.html'));
  }
  next();
});

// 404 Route Handler
app.use((req, res) => {
  const notFoundMessage = `Route ${req.method} ${req.originalUrl} not found`;
  logger.warn('Resource Not Found', { path: req.originalUrl, method: req.method });

  if (req.accepts('json')) {
    return res.status(404).json({
      error: 'Not Found',
      message: notFoundMessage,
      statusCode: 404
    });
  }

  res.status(404).type('txt').send(notFoundMessage);
});

// Centralized Error Handling Middleware
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  logger.error('Unhandled Application Error', {
    error: err.message,
    stack: NODE_ENV === 'production' ? undefined : err.stack,
    path: req.originalUrl
  });

  const statusCode = err.status || err.statusCode || 500;
  res.status(statusCode).json({
    error: statusCode === 500 ? 'Internal Server Error' : err.message,
    statusCode,
    ...(NODE_ENV !== 'production' && { details: err.message })
  });
});

module.exports = app;
