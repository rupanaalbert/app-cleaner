import { Queue } from 'bullmq';
import IORedis from 'ioredis';
import { config } from '../config/index.js';

export const connection = new IORedis(config.redis.url, { maxRetriesPerRequest: null });

const defaults = {
  attempts: 5,
  backoff: { type: 'exponential', delay: 2_000 },
  removeOnComplete: { age: 3_600, count: 1_000 },
  removeOnFail: { age: 7 * 24 * 3_600 },
};

export const matchQueue   = new Queue('matching',  { connection, defaultJobOptions: defaults });
export const paymentQueue = new Queue('payments',  { connection, defaultJobOptions: defaults });
export const ratingQueue  = new Queue('ratings',   { connection, defaultJobOptions: defaults });
export const privacyQueue = new Queue('privacy',   { connection, defaultJobOptions: defaults });
export const notifyQueue  = new Queue('notify',    { connection, defaultJobOptions: { ...defaults, attempts: 3 } });
// The webhook replay sweep drives its own retry cadence in the database
// (next_attempt_at), so a BullMQ-level retry on top would double-count. One
// attempt per tick; the repeat is scheduled by the worker.
export const webhookQueue = new Queue('webhooks',  { connection, defaultJobOptions: { ...defaults, attempts: 1 } });
