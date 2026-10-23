const site = 'https://www.dtek-krem.com.ua';

export function normalize(value) {
  return String(value).trim().replace(/[\u2018\u2019\u02bc`]/g, "'")
    .replace(/\s+/g, ' ').toLocaleLowerCase('uk-UA');
}

export function selectAddress(options, requested) {
  const target = normalize(requested);
  const exact = options.filter(value => normalize(value) === target);
  const matches = exact.length ? exact : options.filter(value => normalize(value).endsWith(` ${target}`));
  if (!target || matches.length !== 1) throw new Error('Address not found or ambiguous');
  return matches[0];
}

export function validateAddress(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid address');
  return Object.fromEntries(['city', 'street', 'building'].map(key => {
    if (typeof value[key] !== 'string' || !value[key].trim() || value[key].length > 160 || /[\u0000-\u001f]/.test(value[key])) {
      throw new Error('A complete address is required');
    }
    return [key, value[key].trim()];
  }));
}

export function intervalsFor(hours) {
  const intervals = [];
  for (let hour = 1; hour <= 24; hour++) {
    const state = hours?.[hour];
    if (!['yes', 'no', 'first', 'second'].includes(state)) throw new Error('Incomplete or unknown schedule');
    if (state === 'yes') continue;
    const startMinute = (hour - 1) * 60 + (state === 'second' ? 30 : 0);
    const endMinute = hour * 60 - (state === 'first' ? 30 : 0);
    intervals.push({ startMinute, endMinute });
  }
  return intervals;
}

export function scheduleResult(raw, address, now = new Date()) {
  const buildingKey = selectAddress(Object.keys(raw.data || {}), address.building);
  const building = raw.data[buildingKey];
  const groups = [...new Set([building.sub_type_reason].flat().filter(value => typeof value === 'string' && value))];
  if (!groups.length || !raw.fact?.update) throw new Error('Missing outage group or update date');
  const days = Object.entries(raw.fact.data || {}).sort(([left], [right]) => Number(left) - Number(right))
    .map(([timestamp, schedule]) => {
      const date = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Kyiv',
        year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(Number(timestamp) * 1000));
      const segments = groups.flatMap(group => intervalsFor(schedule[group]))
        .sort((left, right) => left.startMinute - right.startMinute);
      const intervals = [];
      for (const segment of segments) {
        const previous = intervals.at(-1);
        if (previous && previous.endMinute >= segment.startMinute) {
          previous.endMinute = Math.max(previous.endMinute, segment.endMinute);
        } else intervals.push({ ...segment });
      }
      return { date, intervals };
    });
  if (!days.length) throw new Error('Schedule not published');
  const currentOutage = building.type
    ? [Number(building.type) === 1 ? 'Planned maintenance' : building.sub_type || 'Reported outage',
      building.start_date, building.end_date].filter(Boolean).join(' | ')
    : null;
  return { city: raw.city, street: raw.street, building: buildingKey, groups,
    updatedAt: raw.fact.update, fetchedAt: now.toISOString(), days, currentOutage };
}

export class DtekCollector {
  constructor(context) { this.context = context; }

  async collect(address) {
    const page = await this.context.newPage();
    try {
      await page.goto(`${site}/ua/shutdowns`, { waitUntil: 'domcontentloaded', timeout: 25000 });
      await page.waitForFunction(() => typeof DisconSchedule !== 'undefined' &&
        DisconSchedule.streets && DisconSchedule.fact && document.querySelector('meta[name="csrf-token"]'),
      null, { timeout: 60000 });
      const options = await page.evaluate(() => Object.fromEntries(
        Object.entries(DisconSchedule.streets).map(([city, streets]) => [city, [...streets]])));
      const city = selectAddress(Object.keys(options), address.city);
      const street = selectAddress(options[city], address.street);
      const raw = await page.evaluate(async ({ city, street, site }) => {
        const endpoint = new URL(document.querySelector('meta[name="ajaxUrl"]').content, site);
        if (endpoint.origin !== site || endpoint.pathname !== '/ua/ajax') throw new Error('Unexpected endpoint');
        const body = new URLSearchParams({ method: 'getHomeNum' });
        [{ name: 'city', value: city }, { name: 'street', value: street },
          { name: 'updateFact', value: DisconSchedule.fact.update }].forEach((field, index) => {
          body.set(`data[${index}][name]`, field.name);
          body.set(`data[${index}][value]`, field.value);
        });
        const response = await fetch(endpoint, { method: 'POST', credentials: 'same-origin',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
            'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content,
            'X-Requested-With': 'XMLHttpRequest', 'Accept': 'application/json' },
          body, signal: AbortSignal.timeout(15000) });
        if (!response.ok) throw new Error('DTEK request failed');
        const answer = await response.json();
        if (!answer.result || !answer.data) throw new Error('DTEK lookup failed');
        return { city, street, data: answer.data, fact: answer.fact || DisconSchedule.fact };
      }, { city, street, site });
      return scheduleResult(raw, address);
    } finally { await page.close(); }
  }
}

export class CachedCollector {
  constructor(collect, ttl = 180000) {
    this.collect = collect;
    this.ttl = ttl;
    this.cache = new Map();
    this.pending = new Map();
    this.queue = Promise.resolve();
  }

  fetch(address) {
    const key = JSON.stringify(['city', 'street', 'building'].map(field => normalize(address[field])));
    const cached = this.cache.get(key);
    if (cached && Date.now() - cached.savedAt < this.ttl) return Promise.resolve(cached.value);
    if (this.pending.has(key)) return this.pending.get(key);
    if (this.pending.size >= 4) return Promise.reject(new Error('Collector busy'));
    const operation = this.queue.then(async () => {
      const value = await this.collect(address);
      if (this.cache.size >= 100) this.cache.delete(this.cache.keys().next().value);
      this.cache.set(key, { value, savedAt: Date.now() });
      return value;
    });
    this.queue = operation.catch(() => {});
    const result = operation.finally(() => this.pending.delete(key));
    this.pending.set(key, result);
    return result;
  }
}