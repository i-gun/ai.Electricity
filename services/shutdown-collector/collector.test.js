import assert from 'node:assert/strict';
import test from 'node:test';
import { CachedCollector, intervalsFor, scheduleResult, selectAddress, validateAddress } from './collector.js';

const hours = () => Object.fromEntries(Array.from({ length: 24 }, (_, index) => [index + 1, 'yes']));

test('address matching normalizes apostrophes but never selects arbitrary matches', () => {
  assert.equal(selectAddress(['\u0441. \u041a\u0430\u043c\u2019\u044f\u043d\u0430 \u0413\u0440\u0435\u0431\u043b\u044f'],
    "\u0441. \u041a\u0430\u043c'\u044f\u043d\u0430 \u0413\u0440\u0435\u0431\u043b\u044f"), '\u0441. \u041a\u0430\u043c\u2019\u044f\u043d\u0430 \u0413\u0440\u0435\u0431\u043b\u044f');
  assert.equal(selectAddress(['street Main'], 'Main'), 'street Main');
  assert.equal(selectAddress(['6', '66', '66A'], '66'), '66');
  assert.throws(() => selectAddress(['66A'], '66'));
  assert.throws(() => selectAddress(['city Main', 'village Main'], 'Main'));
  assert.throws(() => selectAddress(['Main'], ''));
});

test('incomplete addresses fail before browser launch', () => {
  for (const value of [null, {}, { city: 'City', street: '', building: '66' }]) {
    assert.throws(() => validateAddress(value));
  }
  assert.deepEqual(validateAddress({ city: ' City ', street: 'Main', building: '66' }),
    { city: 'City', street: 'Main', building: '66' });
});

test('maps full and half-hours and rejects absent or unknown slots', () => {
  const slots = { ...hours(), 1: 'second', 2: 'no', 3: 'first' };
  assert.deepEqual(intervalsFor(slots), [
    { startMinute: 30, endMinute: 60 }, { startMinute: 60, endMinute: 120 },
    { startMinute: 120, endMinute: 150 },
  ]);
  assert.throws(() => intervalsFor({}));
  assert.throws(() => intervalsFor({ ...hours(), 1: 'unknown' }));
});

test('uses exact building, all listed groups, Kyiv dates and source update time', () => {
  const raw = { city: 'City', street: 'Main', data: { 66: { sub_type_reason: ['GPV4.1', 'GPV4.2'], type: '' } },
    fact: { update: '22.10.2026 21:44', data: { 1792702800: {
      'GPV4.1': { ...hours(), 12: 'no', 13: 'no' },
      'GPV4.2': { ...hours(), 13: 'no', 14: 'first', 24: 'second' },
    } } } };
  const result = scheduleResult(raw, { building: '66' });
  assert.deepEqual(result.days, [{ date: '2026-10-23', intervals: [
    { startMinute: 660, endMinute: 810 }, { startMinute: 1410, endMinute: 1440 },
  ] }]);
  assert.equal(result.updatedAt, '22.10.2026 21:44');
  assert.equal(result.currentOutage, null);
  assert.throws(() => scheduleResult(raw, { building: '6' }));
  raw.fact.data = {};
  assert.throws(() => scheduleResult(raw, { building: '66' }));
});

test('shares in-flight calls, caches duplicates and serializes addresses', async () => {
  let calls = 0;
  let active = 0;
  const collector = new CachedCollector(async address => {
    assert.equal(active++, 0);
    await Promise.resolve();
    calls++;
    active--;
    return address;
  });
  const address = { city: 'City', street: 'Main', building: '66' };
  await Promise.all([collector.fetch(address), collector.fetch(address),
    collector.fetch({ ...address, building: '67' })]);
  await collector.fetch(address);
  assert.equal(calls, 2);
});

test('expired cache never hides an upstream failure and failed calls can retry', async () => {
  let fail = false;
  const collector = new CachedCollector(async () => {
    if (fail) throw new Error('unavailable');
    return 'schedule';
  }, 0);
  const address = { city: 'City', street: 'Main', building: '66' };
  assert.equal(await collector.fetch(address), 'schedule');
  fail = true;
  await assert.rejects(collector.fetch(address));
  fail = false;
  assert.equal(await collector.fetch(address), 'schedule');
});