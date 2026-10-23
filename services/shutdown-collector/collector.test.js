import assert from 'node:assert/strict';
import test from 'node:test';
import { CachedCollector, DtekCollector, intervalsFor, resolveAddress, scheduleResult, selectAddress, siteFor, validateAddress } from './collector.js';

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
    { region: 'krem', city: 'City', street: 'Main', building: '66' });
});

test('regions use fixed providers and Kyiv city supports a flat street list', () => {
  assert.equal(siteFor('krem'), 'https://www.dtek-krem.com.ua');
  assert.equal(siteFor('kem'), 'https://www.dtek-kem.com.ua');
  for (const region of ['other', '__proto__', 'https://example.com']) {
    assert.throws(() => validateAddress({ region, city: 'City', street: 'Main', building: '66' }));
  }
  assert.deepEqual(resolveAddress(['street Main'], { region: 'kem', city: '\u041c. \u041a\u0438\u0457\u0432', street: 'Main' }),
    { city: '\u043c. \u041a\u0438\u0457\u0432', street: 'street Main' });
  assert.throws(() => resolveAddress(['Main'], { region: 'kem', city: 'Village', street: 'Main' }));
  assert.deepEqual(resolveAddress({ Village: ['Main'] }, { region: 'krem', city: 'Village', street: 'Main' }),
    { city: 'Village', street: 'Main' });
});

test('cache separates identical address strings by region', async () => {
  let calls = 0;
  const collector = new CachedCollector(async address => { calls++; return address.region; });
  const address = { city: 'Kyiv', street: 'Main', building: '66' };
  assert.equal(await collector.fetch({ ...address, region: 'kem' }), 'kem');
  assert.equal(await collector.fetch({ ...address, region: 'krem' }), 'krem');
  assert.equal(calls, 2);
});

test('browser collector navigates to the selected provider', async () => {
  for (const region of ['kem', 'krem']) {
    let evaluations = 0;
    let destination;
    let closed = false;
    const page = {
      async goto(url) { destination = url; },
      async waitForFunction() {},
      async evaluate() {
        if (evaluations++ === 0) return region === 'kem' ? ['Main'] : { Kyiv: ['Main'] };
        return { city: 'Kyiv', street: 'Main', data: { 66: { sub_type_reason: ['GPV1.1'] } },
          fact: { update: '23.10.2026 12:00', data: { 1792702800: { 'GPV1.1': hours() } } } };
      },
      async close() { closed = true; },
    };
    const result = await new DtekCollector({ async newPage() { return page; } })
      .collect({ region, city: 'Kyiv', street: 'Main', building: '66' });
    assert.equal(destination, `${siteFor(region)}/ua/shutdowns`);
    assert.equal(result.region, region);
    assert.equal(closed, true);
  }
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