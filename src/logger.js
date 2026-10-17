/**
 * Structured JSON Logger for aws-cicd-demo
 * Emits JSON logs compatible with Amazon CloudWatch Logs and modern log aggregators.
 * Includes automated redaction of sensitive fields.
 */

const SENSITIVE_KEY_PATTERNS = [
  /password/i,
  /secret/i,
  /token/i,
  /auth/i,
  /key/i,
  /cookie/i,
  /credential/i,
  /signature/i
];

const LOG_LEVELS = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40
};

const currentLevel = (process.env.LOG_LEVEL || 'info').toLowerCase();
const currentThreshold = LOG_LEVELS[currentLevel] || LOG_LEVELS.info;

/**
 * Deep clone and redact sensitive keys/values from log metadata.
 */
function redact(obj, depth = 0) {
  if (depth > 5) return '[Truncated]';
  if (obj === null || obj === undefined) return obj;

  if (typeof obj !== 'object') {
    return obj;
  }

  if (Array.isArray(obj)) {
    return obj.map(item => redact(item, depth + 1));
  }

  const clean = {};
  for (const [key, value] of Object.entries(obj)) {
    const isSensitive = SENSITIVE_KEY_PATTERNS.some(regex => regex.test(key));
    if (isSensitive) {
      clean[key] = '[REDACTED]';
    } else if (typeof value === 'object' && value !== null) {
      clean[key] = redact(value, depth + 1);
    } else {
      clean[key] = value;
    }
  }
  return clean;
}

function log(level, message, meta = {}) {
  if ((LOG_LEVELS[level] || LOG_LEVELS.info) < currentThreshold) {
    return;
  }

  const logEntry = {
    timestamp: new Date().toISOString(),
    level: level.toUpperCase(),
    service: process.env.APP_NAME || 'aws-cicd-demo',
    version: process.env.APP_VERSION || '1.0.0',
    environment: process.env.NODE_ENV || 'development',
    message,
    ...(meta && Object.keys(meta).length > 0 ? { metadata: redact(meta) } : {})
  };

  const output = JSON.stringify(logEntry);
  if (level === 'error') {
    process.stderr.write(output + '\n');
  } else {
    process.stdout.write(output + '\n');
  }
}

const logger = {
  debug: (msg, meta) => log('debug', msg, meta),
  info: (msg, meta) => log('info', msg, meta),
  warn: (msg, meta) => log('warn', msg, meta),
  error: (msg, meta) => log('error', msg, meta),

  /**
   * Express middleware to log incoming HTTP requests and completion time.
   */
  requestLogger: (req, res, next) => {
    const startTime = process.hrtime.bigint();
    const requestId = req.headers['x-request-id'] || `req-${Date.now()}-${Math.random().toString(36).substring(2, 8)}`;
    req.requestId = requestId;
    res.setHeader('X-Request-Id', requestId);

    res.on('finish', () => {
      const endTime = process.hrtime.bigint();
      const durationMs = Number(endTime - startTime) / 1e6;

      const logData = {
        requestId,
        method: req.method,
        path: req.originalUrl || req.url,
        statusCode: res.statusCode,
        durationMs: Number(durationMs.toFixed(2)),
        userAgent: req.headers['user-agent'] || 'unknown',
        ip: req.ip || req.socket.remoteAddress
      };

      if (res.statusCode >= 500) {
        logger.error('HTTP Request Failed', logData);
      } else if (res.statusCode >= 400) {
        logger.warn('HTTP Client Warning', logData);
      } else {
        logger.info('HTTP Request Handled', logData);
      }
    });

    next();
  }
};

module.exports = logger;
