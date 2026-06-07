#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const dgram = require('dgram');
const fs = require('fs');
const http = require('http');
const net = require('net');
const path = require('path');
const tls = require('tls');
const { URL } = require('url');

const PORT = Number(process.env.PORT || 16781);
const HOST = process.env.HOST || '0.0.0.0';
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const MAX_BODY_BYTES = 8 * 1024 * 1024;

fs.mkdirSync(DATA_DIR, { recursive: true });

const files = {
  config: path.join(DATA_DIR, 'config.json'),
  users: path.join(DATA_DIR, 'users.json'),
  codes: path.join(DATA_DIR, 'codes.json'),
  tracks: path.join(DATA_DIR, 'tracks.json'),
  laps: path.join(DATA_DIR, 'laps.json')
};

function readJSON(file, fallback) {
  try {
    if (!fs.existsSync(file)) return fallback;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

function writeJSON(file, value) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`);
  fs.renameSync(tmp, file);
}

const state = {
  config: readJSON(files.config, {}),
  users: readJSON(files.users, []),
  codes: readJSON(files.codes, []),
  tracks: readJSON(files.tracks, []),
  laps: readJSON(files.laps, [])
};

if (!state.config.jwtSecret) state.config.jwtSecret = crypto.randomBytes(32).toString('hex');
if (!state.config.adminPasswordHash) {
  state.config.adminPasswordHash = hashPassword(process.env.ADMIN_PASSWORD || 'change-me-now');
}
if (!state.config.baseURL) state.config.baseURL = `http://cheap-host1.cheapyun.com:${PORT}`;
if (!state.config.mailFrom) state.config.mailFrom = 'GoKartARLine <noreply@gokart.local>';
persistConfig();

function persistConfig() { writeJSON(files.config, state.config); }
function persistUsers() { writeJSON(files.users, state.users); }
function persistCodes() { writeJSON(files.codes, state.codes); }
function persistTracks() { writeJSON(files.tracks, state.tracks); }
function persistLaps() { writeJSON(files.laps, state.laps); }

function nowISO() { return new Date().toISOString(); }
function id(prefix) { return `${prefix}_${crypto.randomBytes(12).toString('hex')}`; }

function base64url(input) {
  return Buffer.from(input).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function parseBase64url(input) {
  const padded = input.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((input.length + 3) % 4);
  return Buffer.from(padded, 'base64').toString('utf8');
}

function timingSafeEqual(a, b) {
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function hashPassword(password, salt = crypto.randomBytes(16).toString('hex')) {
  const hash = crypto.pbkdf2Sync(String(password), salt, 120000, 32, 'sha256').toString('hex');
  return `pbkdf2$${salt}$${hash}`;
}

function verifyPassword(password, stored) {
  const parts = String(stored || '').split('$');
  if (parts.length !== 3 || parts[0] !== 'pbkdf2') return false;
  return timingSafeEqual(hashPassword(password, parts[1]), stored);
}

function issueToken(user) {
  const payload = base64url(JSON.stringify({ sub: user.id, username: user.username, exp: Date.now() + 1000 * 60 * 60 * 24 * 30 }));
  const sig = base64url(crypto.createHmac('sha256', state.config.jwtSecret).update(payload).digest());
  return `${payload}.${sig}`;
}

function authenticateToken(token) {
  if (!token || !token.includes('.')) return null;
  const [payload, sig] = token.split('.');
  const expected = base64url(crypto.createHmac('sha256', state.config.jwtSecret).update(payload).digest());
  if (!timingSafeEqual(sig, expected)) return null;
  try {
    const decoded = JSON.parse(parseBase64url(payload));
    if (decoded.exp < Date.now()) return null;
    return state.users.find(user => user.id === decoded.sub) || null;
  } catch {
    return null;
  }
}

function escapeHTML(value) {
  return String(value ?? '').replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let total = 0;
    const chunks = [];
    req.on('data', chunk => {
      total += chunk.length;
      if (total > MAX_BODY_BYTES) {
        reject(new Error('request body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

async function readJSONBody(req) {
  const raw = await readBody(req);
  if (!raw.trim()) return {};
  return JSON.parse(raw);
}

function send(res, status, payload, headers = {}) {
  const body = typeof payload === 'string' || Buffer.isBuffer(payload) ? payload : JSON.stringify(payload);
  res.writeHead(status, {
    'Content-Type': typeof payload === 'string' ? 'text/html; charset=utf-8' : 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    ...headers
  });
  res.end(body);
}

function sendJSON(res, status, payload) {
  send(res, status, payload, { 'Content-Type': 'application/json; charset=utf-8' });
}

function errorJSON(res, status, message) {
  sendJSON(res, status, { ok: false, error: message });
}

function adminAuthorized(req) {
  const auth = req.headers.authorization || '';
  const [scheme, encoded] = auth.split(' ');
  if (scheme !== 'Basic' || !encoded) return false;
  const decoded = Buffer.from(encoded, 'base64').toString('utf8');
  const separator = decoded.indexOf(':');
  const username = decoded.slice(0, separator);
  const password = decoded.slice(separator + 1);
  return username === 'admin' && verifyPassword(password, state.config.adminPasswordHash);
}

function requireAdmin(req, res) {
  if (adminAuthorized(req)) return true;
  res.writeHead(401, {
    'WWW-Authenticate': 'Basic realm="GoKartARLine Admin"',
    'Content-Type': 'text/plain; charset=utf-8'
  });
  res.end('admin auth required');
  return false;
}

function requireUser(req, res) {
  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  const user = authenticateToken(token);
  if (!user) errorJSON(res, 401, '未登录或登录已过期');
  return user;
}

function publicUser(user) {
  return { id: user.id, username: user.username, email: user.email, createdAt: user.createdAt };
}

function normalizeEmail(email) {
  return String(email || '').trim().toLowerCase();
}

function validateEmail(email) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

function validateUsername(username) {
  return /^[A-Za-z0-9_\-\u4e00-\u9fff]{2,24}$/.test(String(username || '').trim());
}

function haversine(a, b) {
  const lat1 = a.latitude * Math.PI / 180;
  const lat2 = b.latitude * Math.PI / 180;
  const dLat = (b.latitude - a.latitude) * Math.PI / 180;
  const dLon = (b.longitude - a.longitude) * Math.PI / 180;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 6371000 * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}

function trackLength(points) {
  let total = 0;
  for (let index = 1; index < points.length; index += 1) total += haversine(points[index - 1], points[index]);
  return total;
}

function heading(a, b) {
  const y = Math.sin((b.longitude - a.longitude) * Math.PI / 180) * Math.cos(b.latitude * Math.PI / 180);
  const x = Math.cos(a.latitude * Math.PI / 180) * Math.sin(b.latitude * Math.PI / 180) -
    Math.sin(a.latitude * Math.PI / 180) * Math.cos(b.latitude * Math.PI / 180) * Math.cos((b.longitude - a.longitude) * Math.PI / 180);
  return (Math.atan2(y, x) * 180 / Math.PI + 360) % 360;
}

function angleDelta(a, b) {
  let delta = Math.abs(a - b) % 360;
  return delta > 180 ? 360 - delta : delta;
}

function countTurns(points) {
  let turns = 0;
  let previous = null;
  for (let index = 1; index < points.length; index += 1) {
    const current = heading(points[index - 1], points[index]);
    if (previous !== null && angleDelta(previous, current) > 18) turns += 1;
    previous = current;
  }
  return turns;
}

function bounds(points) {
  const latitudes = points.map(point => point.latitude);
  const longitudes = points.map(point => point.longitude);
  const min = { latitude: Math.min(...latitudes), longitude: Math.min(...longitudes) };
  const max = { latitude: Math.max(...latitudes), longitude: Math.max(...longitudes) };
  return {
    min,
    max,
    width: haversine({ latitude: min.latitude, longitude: min.longitude }, { latitude: min.latitude, longitude: max.longitude }),
    height: haversine({ latitude: min.latitude, longitude: min.longitude }, { latitude: max.latitude, longitude: min.longitude })
  };
}

function sanitizePoint(point) {
  const latitude = Number(point.latitude);
  const longitude = Number(point.longitude);
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude) || latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
    throw new Error('经纬度不合法');
  }
  const speed = Number.isFinite(Number(point.speed)) ? Math.max(0, Math.min(220, Number(point.speed))) : 50;
  const color = ['green', 'orange', 'red'].includes(point.color) ? point.color : 'green';
  return { latitude, longitude, speed, color };
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function finiteNumber(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function sanitizeTelemetrySample(point) {
  const sample = sanitizePoint(point);
  const optionalFields = [
    ['acceleration', -20, 20],
    ['longitudinalAcceleration', -20, 20],
    ['lateralAcceleration', -20, 20],
    ['lineDeviationMeters', 0, 80],
    ['throttleScore', 0, 100],
    ['brakeScore', 0, 100]
  ];
  for (const [field, min, max] of optionalFields) {
    const value = Number(point[field]);
    if (Number.isFinite(value)) sample[field] = Math.round(clamp(value, min, max) * 100) / 100;
  }
  return sample;
}

function sanitizeTelemetrySamples(samples) {
  if (!Array.isArray(samples)) return [];
  const clean = [];
  for (const sample of samples.slice(0, 1000)) {
    try {
      clean.push(sanitizeTelemetrySample(sample));
    } catch {}
  }
  return clean;
}

function pointToLocalMeters(point, origin) {
  const latScale = Math.PI / 180 * 6371000;
  const lonScale = latScale * Math.cos(origin.latitude * Math.PI / 180);
  return {
    x: (point.longitude - origin.longitude) * lonScale,
    y: (point.latitude - origin.latitude) * latScale
  };
}

function distanceToSegmentMeters(point, start, end) {
  const a = pointToLocalMeters(start, point);
  const b = pointToLocalMeters(end, point);
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  const lengthSquared = dx * dx + dy * dy;
  if (lengthSquared <= 0.000001) return haversine(point, start);
  const t = clamp(-(a.x * dx + a.y * dy) / lengthSquared, 0, 1);
  const nearestX = a.x + dx * t;
  const nearestY = a.y + dy * t;
  return Math.sqrt(nearestX * nearestX + nearestY * nearestY);
}

function nearestTrackDeviationMeters(point, trackPoints) {
  if (!Array.isArray(trackPoints) || trackPoints.length < 2) return 0;
  let best = Infinity;
  for (let index = 1; index < trackPoints.length; index += 1) {
    best = Math.min(best, distanceToSegmentMeters(point, trackPoints[index - 1], trackPoints[index]));
  }
  return Number.isFinite(best) ? best : 0;
}

function average(values) {
  return values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : 0;
}

function analyzeLap(track, samples, context) {
  const longitudinal = samples
    .map(sample => Number.isFinite(sample.longitudinalAcceleration) ? sample.longitudinalAcceleration : sample.acceleration)
    .filter(Number.isFinite);
  const lateral = samples.map(sample => sample.lateralAcceleration).filter(Number.isFinite);
  const positive = longitudinal.filter(value => value > 0.2);
  const negative = longitudinal.filter(value => value < -0.2).map(value => Math.abs(value));
  const jerk = [];
  for (let index = 1; index < longitudinal.length; index += 1) jerk.push(Math.abs(longitudinal[index] - longitudinal[index - 1]));
  const deviations = samples.map(sample => {
    if (Number.isFinite(sample.lineDeviationMeters)) return sample.lineDeviationMeters;
    return nearestTrackDeviationMeters(sample, track.points);
  }).filter(Number.isFinite);
  const throttleAvg = average(positive);
  const brakeAvg = average(negative);
  const throttleMax = positive.length ? Math.max(...positive) : 0;
  const brakeMax = negative.length ? Math.max(...negative) : 0;
  const lineDeviationAvg = average(deviations);
  const lineDeviationMax = deviations.length ? Math.max(...deviations) : 0;
  const lateralAvg = average(lateral.map(Math.abs));
  const smoothnessScore = Math.round(clamp(100 - average(jerk) * 22, 0, 100));
  const throttleScore = Math.round(clamp((throttleAvg * 18) + (throttleMax * 8), 0, 100));
  const brakeScore = Math.round(clamp((brakeAvg * 20) + (brakeMax * 7), 0, 100));
  const suggestions = [];
  if (lineDeviationAvg > 4 || lineDeviationMax > 10) suggestions.push('行车线偏离偏大，优先复盘入弯点和出弯外放位置。');
  if (brakeMax > 5 || brakeAvg > 2.8) suggestions.push('刹车峰值偏高，建议更早更线性地建立制动力。');
  if (brakeAvg < 0.7 && finiteNumber(context.speedKph) > 35) suggestions.push('减速特征偏弱，重刹区需要更明确的初段刹车。');
  if (throttleMax > 4.5 && smoothnessScore < 65) suggestions.push('油门回补较猛，出弯可尝试分段加油减少后段修正。');
  if (positive.length < longitudinal.length * 0.08 && finiteNumber(context.speedKph) > 25) suggestions.push('有效加速区偏少，确认出弯后是否能更早全油。');
  if (smoothnessScore < 55) suggestions.push('加速度波动较大，建议保持油门和刹车输入连续。');
  if (finiteNumber(context.gpsAccuracy) > 10) suggestions.push('GPS 精度偏低，本圈行车线偏离数据仅作参考。');
  if (!suggestions.length) suggestions.push('本圈输入节奏稳定，下一步可对比排行榜用户的最短行车线。');
  return {
    sampleCount: samples.length,
    throttleScore,
    throttleAvg: Math.round(throttleAvg * 100) / 100,
    throttleMax: Math.round(throttleMax * 100) / 100,
    brakeScore,
    brakeAvg: Math.round(brakeAvg * 100) / 100,
    brakeMax: Math.round(brakeMax * 100) / 100,
    lateralAvg: Math.round(lateralAvg * 100) / 100,
    lineDeviationAvg: Math.round(lineDeviationAvg * 10) / 10,
    lineDeviationMax: Math.round(lineDeviationMax * 10) / 10,
    smoothnessScore,
    suggestions: suggestions.slice(0, 4)
  };
}

function resampleClosedPath(points, targetCount) {
  if (points.length <= 1) return points;
  const distances = [0];
  for (let index = 1; index < points.length; index += 1) distances.push(distances[index - 1] + haversine(points[index - 1], points[index]));
  const total = distances[distances.length - 1];
  if (total <= 0) return points.slice(0, targetCount);
  const out = [];
  for (let sample = 0; sample < targetCount; sample += 1) {
    const target = total * sample / targetCount;
    let segment = 1;
    while (segment < distances.length - 1 && distances[segment] < target) segment += 1;
    const beforeDistance = distances[segment - 1];
    const afterDistance = distances[segment];
    const ratio = afterDistance === beforeDistance ? 0 : (target - beforeDistance) / (afterDistance - beforeDistance);
    const before = points[segment - 1];
    const after = points[segment];
    out.push({
      latitude: before.latitude + (after.latitude - before.latitude) * ratio,
      longitude: before.longitude + (after.longitude - before.longitude) * ratio,
      speed: before.speed + (after.speed - before.speed) * ratio,
      color: ratio < 0.5 ? before.color : after.color
    });
  }
  out.push({ ...out[0] });
  return out;
}

function normalizeTrack(body) {
  const rawPoints = Array.isArray(body.points) ? body.points : [];
  if (rawPoints.length < 20) throw new Error('轨迹点至少需要20个');
  const points = rawPoints.map(sanitizePoint);
  const name = String(body.trackName || body.name || '').trim();
  if (!name) throw new Error('赛道名称不能为空');
  const measuredLength = trackLength(points);
  const normalized = measuredLength > 0 && points.length !== 121 ? resampleClosedPath(points, 120) : points;
  return {
    trackName: name.slice(0, 80),
    trackLength: Math.round((Number(body.trackLength) > 0 ? Number(body.trackLength) : trackLength(normalized)) * 10) / 10,
    cornerCount: Number.isInteger(Number(body.cornerCount)) ? Number(body.cornerCount) : countTurns(normalized),
    points: normalized
  };
}

function looksLikeKartTrack(track) {
  const points = track.points;
  const length = trackLength(points);
  const box = bounds(points);
  const closedDistance = haversine(points[0], points[points.length - 1]);
  const turns = countTurns(points);
  const maxDimension = Math.max(box.width, box.height);
  const minDimension = Math.min(box.width, box.height);
  const reasons = [];
  if (points.length < 40) reasons.push('轨迹点过少');
  if (length < 120 || length > 5000) reasons.push('赛道长度不像卡丁车场');
  if (closedDistance > Math.max(25, length * 0.08)) reasons.push('赛道未闭合');
  if (maxDimension < 35 || minDimension < 8 || maxDimension > 2500) reasons.push('地图范围不合理');
  if (turns < 4) reasons.push('弯道特征不足');
  return { ok: reasons.length === 0, reasons, length, turns, bounds: box, closedDistance };
}

function trackSummary(track) {
  return {
    id: track.id,
    trackName: track.trackName,
    trackLength: track.trackLength,
    cornerCount: track.cornerCount,
    pointCount: track.points.length,
    createdAt: track.createdAt,
    updatedAt: track.updatedAt,
    authorName: track.authorName,
    downloadCount: track.downloadCount || 0,
    lapCount: state.laps.filter(lap => lap.trackId === track.id).length,
    thumbnailURL: `/api/tracks/${encodeURIComponent(track.id)}/thumbnail.svg`
  };
}

function leaderboard(trackId) {
  const bestByUser = new Map();
  for (const lap of state.laps.filter(item => item.trackId === trackId && Number.isFinite(item.lapTimeMs))) {
    const previous = bestByUser.get(lap.userId);
    if (!previous || lap.lapTimeMs < previous.lapTimeMs) bestByUser.set(lap.userId, lap);
  }
  return Array.from(bestByUser.values())
    .sort((a, b) => a.lapTimeMs - b.lapTimeMs)
    .slice(0, 10)
    .map((lap, index) => ({
      rank: index + 1,
      username: lap.username,
      lapTimeMs: lap.lapTimeMs,
      speedKph: lap.speedKph || 0,
      gpsAccuracy: lap.gpsAccuracy || 0,
      throttleScore: lap.analysis?.throttleScore || 0,
      brakeScore: lap.analysis?.brakeScore || 0,
      lineDeviationAvg: lap.analysis?.lineDeviationAvg || 0,
      lineDeviationMax: lap.analysis?.lineDeviationMax || 0,
      smoothnessScore: lap.analysis?.smoothnessScore || 0,
      suggestions: lap.analysis?.suggestions || [],
      analysis: lap.analysis || null,
      createdAt: lap.createdAt
    }));
}

function optimizeTrackWithLap(track, samples) {
  if (!Array.isArray(samples) || samples.length < 20) return track;
  const clean = samples.map(sanitizePoint);
  const lapPath = resampleClosedPath(clean, track.points.length - 1);
  const current = resampleClosedPath(track.points, track.points.length - 1);
  const optimized = current.map((point, index) => {
    const sample = lapPath[index] || point;
    return {
      latitude: point.latitude * 0.88 + sample.latitude * 0.12,
      longitude: point.longitude * 0.88 + sample.longitude * 0.12,
      speed: point.speed,
      color: point.color
    };
  });
  optimized.push({ ...optimized[0] });
  track.points = optimized;
  track.trackLength = Math.round(trackLength(optimized) * 10) / 10;
  track.updatedAt = nowISO();
  track.optimizedLapCount = (track.optimizedLapCount || 0) + 1;
  return track;
}

function svgThumbnail(track) {
  const width = 420;
  const height = 260;
  const padding = 24;
  const box = bounds(track.points);
  const latSpan = Math.max(box.max.latitude - box.min.latitude, 0.000001);
  const lonSpan = Math.max(box.max.longitude - box.min.longitude, 0.000001);
  const points = track.points.map(point => {
    const x = padding + (point.longitude - box.min.longitude) / lonSpan * (width - padding * 2);
    const y = height - padding - (point.latitude - box.min.latitude) / latSpan * (height - padding * 2);
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(' ');
  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">
  <rect width="${width}" height="${height}" rx="24" fill="#050505"/>
  <polyline points="${points}" fill="none" stroke="#00ff46" stroke-width="8" stroke-linejoin="round" stroke-linecap="round"/>
  <polyline points="${points}" fill="none" stroke="#ffffff" stroke-opacity=".42" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>
  <circle cx="${points.split(' ')[0].split(',')[0]}" cy="${points.split(' ')[0].split(',')[1]}" r="7" fill="#ff2f00"/>
  <text x="18" y="236" fill="#fff" font-size="18" font-family="Arial, sans-serif">${escapeHTML(track.trackName)}</text>
</svg>`;
}

async function sendVerificationEmail(email, code) {
  if (!state.config.smtpHost || !state.config.smtpPort) return { sent: false, reason: 'SMTP未配置' };
  const subject = 'GoKartARLine 验证码';
  const body = `你的 GoKartARLine 注册验证码是：${code}\n\n验证码10分钟内有效。如果不是你本人操作，请忽略。`;
  try {
    await smtpSend({
      host: state.config.smtpHost,
      port: Number(state.config.smtpPort),
      secure: Boolean(state.config.smtpSecure),
      username: state.config.smtpUser || '',
      password: state.config.smtpPassword || '',
      from: state.config.mailFrom || 'GoKartARLine <noreply@gokart.local>',
      to: email,
      subject,
      body
    });
    return { sent: true };
  } catch (error) {
    return { sent: false, reason: error.message };
  }
}

function smtpSend(options) {
  return new Promise((resolve, reject) => {
    let socket = options.secure
      ? tls.connect({ host: options.host, port: options.port, servername: options.host })
      : net.connect({ host: options.host, port: options.port });
    let buffer = '';
    let closed = false;

    function fail(error) {
      if (closed) return;
      closed = true;
      try { socket.destroy(); } catch {}
      reject(error);
    }

    function readResponse() {
      return new Promise((ok, bad) => {
        const timeout = setTimeout(() => bad(new Error('SMTP响应超时')), 15000);
        function onData(chunk) {
          buffer += chunk.toString('utf8');
          const lines = buffer.split(/\r?\n/).filter(Boolean);
          const last = lines[lines.length - 1] || '';
          if (/^\d{3}\s/.test(last)) {
            clearTimeout(timeout);
            socket.off('data', onData);
            const response = buffer;
            buffer = '';
            ok(response);
          }
        }
        socket.on('data', onData);
      });
    }

    async function command(line, expected = /^[23]/) {
      socket.write(`${line}\r\n`);
      const response = await readResponse();
      if (!expected.test(response)) throw new Error(`SMTP命令失败：${line}`);
      return response;
    }

    socket.on('error', fail);
    socket.on('connect', async () => {
      try {
        await readResponse();
        let ehlo = await command('EHLO gokart.local');
        if (!options.secure && /STARTTLS/i.test(ehlo)) {
          await command('STARTTLS', /^220/);
          socket = tls.connect({ socket, servername: options.host });
          await new Promise((ok, bad) => {
            socket.once('secureConnect', ok);
            socket.once('error', bad);
          });
          buffer = '';
          await command('EHLO gokart.local');
        }
        if (options.username && options.password) {
          await command('AUTH LOGIN', /^334/);
          await command(Buffer.from(options.username).toString('base64'), /^334/);
          await command(Buffer.from(options.password).toString('base64'), /^235/);
        }
        const fromAddress = extractEmail(options.from);
        await command(`MAIL FROM:<${fromAddress}>`);
        await command(`RCPT TO:<${options.to}>`);
        await command('DATA', /^354/);
        const message = [
          `From: ${options.from}`,
          `To: ${options.to}`,
          `Subject: ${options.subject}`,
          'Content-Type: text/plain; charset=utf-8',
          '',
          options.body,
          '.'
        ].join('\r\n');
        await command(message);
        await command('QUIT', /^221/);
        closed = true;
        socket.end();
        resolve();
      } catch (error) {
        fail(error);
      }
    });
  });
}

function extractEmail(value) {
  const match = String(value).match(/<([^>]+)>/);
  return match ? match[1] : String(value).trim();
}

async function handleAPI(req, res, url) {
  if (req.method === 'OPTIONS') return sendJSON(res, 204, {});

  if (req.method === 'GET' && url.pathname === '/api/health') {
    return sendJSON(res, 200, { ok: true, service: 'GoKartARLine online', port: PORT, tcp: true, udp: true, time: nowISO() });
  }

  if (req.method === 'POST' && url.pathname === '/api/auth/request-code') {
    const body = await readJSONBody(req);
    const email = normalizeEmail(body.email);
    if (!validateEmail(email)) return errorJSON(res, 400, '邮箱格式不正确');
    const code = String(crypto.randomInt(100000, 999999));
    state.codes = state.codes.filter(item => item.email !== email && Date.parse(item.expiresAt) > Date.now());
    state.codes.push({ email, codeHash: hashPassword(code), createdAt: nowISO(), expiresAt: new Date(Date.now() + 10 * 60 * 1000).toISOString(), used: false });
    persistCodes();
    const mail = await sendVerificationEmail(email, code);
    return sendJSON(res, 200, { ok: true, emailSent: mail.sent, message: mail.sent ? '验证码已发送' : `验证码已生成，邮件未发送：${mail.reason}` });
  }

  if (req.method === 'POST' && url.pathname === '/api/auth/register') {
    const body = await readJSONBody(req);
    const username = String(body.username || '').trim();
    const email = normalizeEmail(body.email);
    const password = String(body.password || '');
    const code = String(body.code || '').trim();
    if (!validateUsername(username)) return errorJSON(res, 400, '用户名需为2-24位中文、字母、数字、下划线或短横线');
    if (!validateEmail(email)) return errorJSON(res, 400, '邮箱格式不正确');
    if (password.length < 6) return errorJSON(res, 400, '密码至少6位');
    if (state.users.some(user => user.username.toLowerCase() === username.toLowerCase())) return errorJSON(res, 409, '用户名已存在');
    if (state.users.some(user => user.email === email)) return errorJSON(res, 409, '邮箱已注册');
    const record = state.codes.find(item => item.email === email && !item.used && Date.parse(item.expiresAt) > Date.now() && verifyPassword(code, item.codeHash));
    if (!record) return errorJSON(res, 400, '验证码错误或已过期');
    record.used = true;
    const user = { id: id('usr'), username, email, passwordHash: hashPassword(password), createdAt: nowISO() };
    state.users.push(user);
    persistCodes();
    persistUsers();
    return sendJSON(res, 200, { ok: true, token: issueToken(user), user: publicUser(user) });
  }

  if (req.method === 'POST' && url.pathname === '/api/auth/login') {
    const body = await readJSONBody(req);
    const login = String(body.login || body.username || body.email || '').trim().toLowerCase();
    const password = String(body.password || '');
    const user = state.users.find(item => item.email === login || item.username.toLowerCase() === login);
    if (!user || !verifyPassword(password, user.passwordHash)) return errorJSON(res, 401, '用户名或密码错误');
    return sendJSON(res, 200, { ok: true, token: issueToken(user), user: publicUser(user) });
  }

  if (req.method === 'GET' && url.pathname === '/api/me') {
    const user = requireUser(req, res);
    if (!user) return;
    return sendJSON(res, 200, { ok: true, user: publicUser(user) });
  }

  if (req.method === 'GET' && url.pathname === '/api/tracks') {
    const query = String(url.searchParams.get('q') || '').trim().toLowerCase();
    const tracks = state.tracks
      .filter(track => track.verified)
      .filter(track => !query || track.trackName.toLowerCase().includes(query) || track.authorName.toLowerCase().includes(query))
      .sort((a, b) => Date.parse(b.updatedAt || b.createdAt) - Date.parse(a.updatedAt || a.createdAt))
      .slice(0, 100)
      .map(trackSummary);
    return sendJSON(res, 200, { ok: true, tracks });
  }

  if (req.method === 'POST' && url.pathname === '/api/tracks') {
    const user = requireUser(req, res);
    if (!user) return;
    const body = await readJSONBody(req);
    let track;
    try {
      track = normalizeTrack(body);
    } catch (error) {
      return errorJSON(res, 400, error.message);
    }
    const verification = looksLikeKartTrack(track);
    if (!verification.ok) return errorJSON(res, 422, `未通过真卡丁车场识别：${verification.reasons.join('、')}`);
    const remoteTrack = {
      ...track,
      id: id('trk'),
      authorId: user.id,
      authorName: user.username,
      verified: true,
      verification,
      downloadCount: 0,
      optimizedLapCount: 0,
      createdAt: nowISO(),
      updatedAt: nowISO()
    };
    state.tracks.push(remoteTrack);
    persistTracks();
    return sendJSON(res, 200, { ok: true, track: trackSummary(remoteTrack), remoteID: remoteTrack.id });
  }

  const trackMatch = url.pathname.match(/^\/api\/tracks\/([^/]+)(?:\/([^/]+))?$/);
  if (trackMatch) {
    const trackId = decodeURIComponent(trackMatch[1]);
    const action = trackMatch[2] || '';
    const track = state.tracks.find(item => item.id === trackId && item.verified);
    if (!track) return errorJSON(res, 404, '赛道不存在');

    if (req.method === 'GET' && !action) return sendJSON(res, 200, { ok: true, track: { ...trackSummary(track), points: track.points } });
    if (req.method === 'GET' && action === 'download') {
      track.downloadCount = (track.downloadCount || 0) + 1;
      persistTracks();
      return sendJSON(res, 200, {
        ok: true,
        track: {
          remoteID: track.id,
          trackName: track.trackName,
          trackLength: track.trackLength,
          cornerCount: track.cornerCount,
          points: track.points
        }
      });
    }
    if (req.method === 'GET' && action === 'leaderboard') return sendJSON(res, 200, { ok: true, leaderboard: leaderboard(track.id) });
    if (req.method === 'GET' && action === 'thumbnail.svg') {
      res.writeHead(200, { 'Content-Type': 'image/svg+xml; charset=utf-8' });
      return res.end(svgThumbnail(track));
    }
    if (req.method === 'POST' && action === 'laps') {
      const user = requireUser(req, res);
      if (!user) return;
      const body = await readJSONBody(req);
      const result = handleLapObject({ ...body, trackId: track.id }, user);
      if (!result.ok) return errorJSON(res, result.status || 400, result.error);
      return sendJSON(res, 200, result);
    }
  }

  return errorJSON(res, 404, '接口不存在');
}

function handleLapObject(body, user) {
  const track = state.tracks.find(item => item.id === body.trackId && item.verified);
  if (!track) return { ok: false, status: 404, error: '赛道不存在' };
  const lapTimeMs = Number(body.lapTimeMs);
  if (!Number.isFinite(lapTimeMs) || lapTimeMs < 5000 || lapTimeMs > 30 * 60 * 1000) return { ok: false, error: '圈速不合法' };
  const speedKph = Number(body.speedKph || 0);
  const gpsAccuracy = Number(body.gpsAccuracy || 0);
  const samples = sanitizeTelemetrySamples(body.samples);
  const analysis = analyzeLap(track, samples, { lapTimeMs, speedKph, gpsAccuracy });
  const lap = {
    id: id('lap'),
    trackId: track.id,
    userId: user.id,
    username: user.username,
    lapTimeMs: Math.round(lapTimeMs),
    speedKph: Number.isFinite(speedKph) ? Math.round(speedKph * 10) / 10 : 0,
    gpsAccuracy: Number.isFinite(gpsAccuracy) ? Math.round(gpsAccuracy * 10) / 10 : 0,
    sampleCount: samples.length,
    analysis,
    createdAt: nowISO()
  };
  state.laps.push(lap);
  try { optimizeTrackWithLap(track, samples); } catch {}
  persistLaps();
  persistTracks();
  return { ok: true, lap, analysis, leaderboard: leaderboard(track.id) };
}

async function handleAdmin(req, res, url) {
  if (!requireAdmin(req, res)) return;
  if (req.method === 'POST' && url.pathname === '/admin/config') {
    const raw = await readBody(req);
    const params = new URLSearchParams(raw);
    state.config.baseURL = params.get('baseURL') || state.config.baseURL;
    state.config.smtpHost = params.get('smtpHost') || '';
    state.config.smtpPort = Number(params.get('smtpPort') || 0);
    state.config.smtpSecure = params.get('smtpSecure') === 'on';
    state.config.smtpUser = params.get('smtpUser') || '';
    const smtpPassword = params.get('smtpPassword') || '';
    if (smtpPassword) state.config.smtpPassword = smtpPassword;
    state.config.mailFrom = params.get('mailFrom') || state.config.mailFrom;
    const adminPassword = params.get('adminPassword') || '';
    if (adminPassword) state.config.adminPasswordHash = hashPassword(adminPassword);
    persistConfig();
    res.writeHead(302, { Location: '/admin' });
    return res.end();
  }
  const latestCodes = state.codes.slice(-10).reverse();
  const rows = state.tracks.slice().reverse().map(track => `<tr><td>${escapeHTML(track.trackName)}</td><td>${escapeHTML(track.authorName)}</td><td>${track.points.length}</td><td>${Math.round(track.trackLength)}m</td><td>${track.downloadCount || 0}</td><td>${track.optimizedLapCount || 0}</td><td>${escapeHTML(track.createdAt)}</td></tr>`).join('');
  const codeRows = latestCodes.map(code => `<tr><td>${escapeHTML(code.email)}</td><td>${escapeHTML(code.createdAt)}</td><td>${escapeHTML(code.expiresAt)}</td><td>${code.used ? 'yes' : 'no'}</td></tr>`).join('');
  return send(res, 200, `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>GoKartARLine 后端配置</title>
  <style>
    body{margin:0;background:#050505;color:#fff;font:15px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    main{max-width:1120px;margin:0 auto;padding:28px}
    .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:14px}
    .card,form,table{background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.2);border-radius:24px;box-shadow:0 24px 60px rgba(0,0,0,.5);backdrop-filter:blur(18px)}
    .card{padding:20px}.num{font-size:32px;font-weight:800}
    form{padding:22px;margin:18px 0;display:grid;gap:12px}
    label{display:grid;gap:6px;color:rgba(255,255,255,.72)}
    input{background:rgba(0,0,0,.5);border:1px solid rgba(255,255,255,.24);border-radius:14px;color:#fff;padding:12px}
    button{border:0;border-radius:999px;padding:12px 20px;background:rgba(255,255,255,.18);color:#fff}
    table{width:100%;border-collapse:collapse;overflow:hidden;margin:18px 0}
    th,td{padding:12px;border-bottom:1px solid rgba(255,255,255,.12);text-align:left}
    a{color:#8fd7ff}
  </style>
</head>
<body>
  <main>
    <h1>GoKartARLine 后端配置</h1>
    <p>HTTP API 与 UDP 遥测都监听 ${PORT} 端口。</p>
    <section class="grid">
      <div class="card"><div class="num">${state.users.length}</div><div>用户</div></div>
      <div class="card"><div class="num">${state.tracks.length}</div><div>分享赛道</div></div>
      <div class="card"><div class="num">${state.laps.length}</div><div>圈速记录</div></div>
      <div class="card"><div class="num">${PORT}</div><div>TCP/UDP端口</div></div>
    </section>
    <form method="post" action="/admin/config">
      <h2>服务配置</h2>
      <label>客户端 Base URL<input name="baseURL" value="${escapeHTML(state.config.baseURL)}"></label>
      <label>SMTP Host<input name="smtpHost" value="${escapeHTML(state.config.smtpHost || '')}"></label>
      <label>SMTP Port<input name="smtpPort" value="${escapeHTML(state.config.smtpPort || '')}"></label>
      <label><span><input type="checkbox" name="smtpSecure" ${state.config.smtpSecure ? 'checked' : ''}> 使用隐式 TLS</span></label>
      <label>SMTP 用户<input name="smtpUser" value="${escapeHTML(state.config.smtpUser || '')}"></label>
      <label>SMTP 密码<input type="password" name="smtpPassword" placeholder="留空则不修改"></label>
      <label>发件人<input name="mailFrom" value="${escapeHTML(state.config.mailFrom || '')}"></label>
      <label>管理员密码<input type="password" name="adminPassword" placeholder="留空则不修改"></label>
      <button type="submit">保存配置</button>
    </form>
    <h2>分享赛道</h2>
    <table><thead><tr><th>名称</th><th>用户</th><th>点数</th><th>长度</th><th>下载</th><th>优化</th><th>创建</th></tr></thead><tbody>${rows || '<tr><td colspan="7">暂无</td></tr>'}</tbody></table>
    <h2>最近验证码</h2>
    <p>如果 SMTP 未配置，验证码不会在接口返回；请配置邮件后再注册。</p>
    <table><thead><tr><th>邮箱</th><th>创建</th><th>过期</th><th>已用</th></tr></thead><tbody>${codeRows || '<tr><td colspan="4">暂无</td></tr>'}</tbody></table>
  </main>
</body>
</html>`);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  try {
    if (url.pathname === '/') {
      res.writeHead(302, { Location: '/admin' });
      return res.end();
    }
    if (url.pathname.startsWith('/admin')) return await handleAdmin(req, res, url);
    if (url.pathname.startsWith('/api')) return await handleAPI(req, res, url);
    return errorJSON(res, 404, 'not found');
  } catch (error) {
    return errorJSON(res, 500, error.message || 'server error');
  }
});

const udp = dgram.createSocket('udp4');
udp.on('message', (message, rinfo) => {
  let response;
  try {
    const body = JSON.parse(message.toString('utf8'));
    if (body.type === 'ping') {
      response = { ok: true, pong: true, time: nowISO() };
    } else if (body.type === 'lap') {
      const user = authenticateToken(body.token);
      response = user ? handleLapObject(body, user) : { ok: false, error: '未登录或登录已过期' };
    } else {
      response = { ok: false, error: 'unsupported udp type' };
    }
  } catch (error) {
    response = { ok: false, error: error.message };
  }
  udp.send(Buffer.from(JSON.stringify(response)), rinfo.port, rinfo.address);
});

server.listen(PORT, HOST, () => {
  console.log(`GoKartARLine HTTP/API/admin listening on ${HOST}:${PORT}`);
});

udp.bind(PORT, HOST, () => {
  console.log(`GoKartARLine UDP telemetry listening on ${HOST}:${PORT}`);
});
