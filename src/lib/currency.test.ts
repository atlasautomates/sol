import assert from "node:assert/strict";
import { test } from "node:test";
import {
	type CachedRates,
	type CurrencyRates,
	createCurrencyRates,
	lookupCurrencyConversion,
	parseCurrencyConversion,
} from "./currency.ts";

const RATES: CurrencyRates = {
	base: "EUR",
	date: "2026-11-25",
	rates: { USD: 1.25, GBP: 0.8, JPY: 160 },
};

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;
const NOW = Date.UTC(2026, 10, 26, 12);

// "<left value> <left label> = <right value> <right label>", or null.
function shown(result: ReturnType<typeof parseCurrencyConversion>) {
	return result?.kind === "comparison"
		? `${result.left.value} ${result.left.label} = ${result.right.value} ${result.right.label}`
		: result;
}

function converts(cases: Array<[string, string | null]>) {
	for (const [query, expected] of cases) {
		assert.equal(
			shown(parseCurrencyConversion(query, RATES)),
			expected,
			`query: ${query}`,
		);
	}
}

test("an amount converts between codes, in any case, through the euro", () => {
	converts([
		["100 usd to eur", "100 USD = 80.00 EUR"],
		["100 USD to EUR", "100 USD = 80.00 EUR"],
		["100 Usd in gbp", "100 USD = 64.00 GBP"],
		["100usd to eur", "100 USD = 80.00 EUR"],
		["1,000 usd in eur", "1,000 USD = 800.00 EUR"],
		["12.5 gbp to usd", "12.5 GBP = 19.53 USD"],
		["50 eur to eur", "50 EUR = 50.00 EUR"],
	]);
});

test("$ € £ ¥ stand for USD EUR GBP JPY, before or after the amount", () => {
	converts([
		["€50 in gbp", "50 EUR = 40.00 GBP"],
		["$100 to eur", "100 USD = 80.00 EUR"],
		["100$ to eur", "100 USD = 80.00 EUR"],
		["100 € to usd", "100 EUR = 125.00 USD"],
		["£ 10 to usd", "10 GBP = 15.63 USD"],
		["¥999 to usd", "999 JPY = 7.80 USD"],
		["$100 to £", "100 USD = 64.00 GBP"],
		["$100 usd to eur", "100 USD = 80.00 EUR"],
		["$100 gbp to eur", null],
	]);
});

test("yen show whole amounts", () => {
	converts([["100 usd to jpy", "100 USD = 12800 JPY"]]);
});

test("the result row names the rate and the day it dates from", () => {
	const result = parseCurrencyConversion("100 usd to gbp", RATES);
	assert.equal(result?.kind, "comparison");
	assert.equal(
		result?.kind === "comparison" ? result.footer : null,
		"1 USD = 0.64 GBP · ECB rate of 2026-11-25",
	);
});

test("only codes in the rates table convert", () => {
	converts([
		["100 cad to eur", null],
		["100 usd to xyz", null],
		["5 m to ft", null],
		["100 kgs to lbs", null],
		["100 usd", null],
		["usd to eur", null],
		["100 usd to e", null],
		["100 usd to euro", null],
		["2+2", null],
	]);
	assert.equal(parseCurrencyConversion("100 usd to eur", null), null);
});

test("negative amounts, decimal commas and the amount as typed", () => {
	converts([
		["-5 usd to eur", "-5 USD = -4.00 EUR"],
		["-€5 to usd", null],
		["1,6 eur to usd", "1,6 EUR = 2.00 USD"],
		["1.000,5 eur to usd", "1.000,5 EUR = 1250.63 USD"],
		["1234567.89 usd to eur", "1234567.89 USD = 987654.31 EUR"],
		["100 USD TO EUR", "100 USD = 80.00 EUR"],
	]);
});

test("a long pasted query returns nothing, fast", async () => {
	const query = `1 ${"lorem ipsum in dolor to ".repeat(8000)}`;
	const { source, calls } = fakeSource({ responses: [FRANKFURTER_RESPONSE] });
	const rates = createCurrencyRates(source);
	const started = performance.now();
	assert.equal(parseCurrencyConversion(query, RATES), null);
	assert.equal(
		lookupCurrencyConversion(query, rates, () => {}),
		null,
	);
	assert.ok(performance.now() - started < 50, "took over 50 ms");
	await tick();
	assert.equal(calls.fetches, 0);
});

// A fake rates source: an in-memory cache file and a scripted network.
function fakeSource(options: {
	cache?: unknown;
	responses?: Array<unknown | Error>;
	now?: number;
}) {
	const calls = { fetches: 0, writes: [] as CachedRates[] };
	const responses = [...(options.responses ?? [])];
	const clock = { now: options.now ?? NOW };
	const source = {
		readCache: async () => options.cache ?? null,
		writeCache: (rates: CachedRates) => {
			calls.writes.push(rates);
		},
		fetchLatest: async () => {
			calls.fetches += 1;
			const next = responses.shift() ?? new Error("offline");
			if (next instanceof Error) {
				throw next;
			}
			return next;
		},
		now: () => clock.now,
	};
	return { source, calls, clock };
}

const FRANKFURTER_RESPONSE = {
	amount: 1,
	base: "EUR",
	date: "2026-11-26",
	rates: { USD: 1.1, GBP: 0.85, JPY: 175 },
};

test("with no cache, the first refresh fetches and caches the rates", async () => {
	const { source, calls } = fakeSource({ responses: [FRANKFURTER_RESPONSE] });
	const rates = createCurrencyRates(source);

	const fetched = await rates.refresh();

	assert.equal(calls.fetches, 1);
	assert.equal(fetched?.date, "2026-11-26");
	assert.equal(fetched?.rates.USD, 1.1);
	assert.equal(rates.current()?.date, "2026-11-26");
	assert.deepEqual(calls.writes, [
		{
			base: "EUR",
			date: "2026-11-26",
			rates: { USD: 1.1, GBP: 0.85, JPY: 175, EUR: 1 },
			fetchedAt: NOW,
		},
	]);
});

test("a cache under a day old is used without fetching", async () => {
	const { source, calls } = fakeSource({
		cache: { ...RATES, fetchedAt: NOW - 23 * HOUR },
		responses: [FRANKFURTER_RESPONSE],
	});
	const rates = createCurrencyRates(source);

	assert.equal((await rates.refresh())?.date, "2026-11-25");
	assert.equal(calls.fetches, 0);
});

test("a cache a day old is shown while one fetch replaces it", async () => {
	const { source, calls } = fakeSource({
		cache: { ...RATES, fetchedAt: NOW - DAY },
		responses: [FRANKFURTER_RESPONSE],
	});
	const rates = createCurrencyRates(source);
	await rates.refresh();
	assert.equal(calls.fetches, 1);
	assert.equal(rates.current()?.date, "2026-11-26");

	await rates.refresh();
	assert.equal(calls.fetches, 1);
});

test("refreshes at the same time share one fetch", async () => {
	const { source, calls } = fakeSource({ responses: [FRANKFURTER_RESPONSE] });
	const rates = createCurrencyRates(source);

	const [first, second] = await Promise.all([rates.refresh(), rates.refresh()]);

	assert.equal(calls.fetches, 1);
	assert.equal(first, second);
});

test("offline, the stale cache stays, and the fetch waits an hour to retry", async () => {
	const { source, calls, clock } = fakeSource({
		cache: { ...RATES, fetchedAt: NOW - 3 * DAY },
		responses: [
			new Error("offline"),
			new Error("offline"),
			FRANKFURTER_RESPONSE,
		],
	});
	const rates = createCurrencyRates(source);

	assert.equal((await rates.refresh())?.date, "2026-11-25");
	assert.equal(calls.fetches, 1);
	assert.deepEqual(calls.writes, []);

	clock.now += HOUR - 1;
	assert.equal((await rates.refresh())?.date, "2026-11-25");
	assert.equal(calls.fetches, 1);

	clock.now += 1;
	await rates.refresh();
	assert.equal(calls.fetches, 2);

	clock.now += HOUR;
	assert.equal((await rates.refresh())?.date, "2026-11-26");
	assert.equal(calls.fetches, 3);
});

test("offline with no cache, there are no rates", async () => {
	const { source } = fakeSource({});
	const rates = createCurrencyRates(source);

	assert.equal(await rates.refresh(), null);
	assert.equal(rates.current(), null);
});

test("a response or cache that is not a rates table is ignored", async () => {
	const { source, calls } = fakeSource({
		cache: { message: "not rates" },
		responses: [{ message: "not found" }],
	});
	const rates = createCurrencyRates(source);

	assert.equal(await rates.refresh(), null);
	assert.equal(calls.fetches, 1);
	assert.deepEqual(calls.writes, []);

	for (const broken of [
		{ ...FRANKFURTER_RESPONSE, date: "yesterday" },
		{ ...FRANKFURTER_RESPONSE, rates: { USD: -1 } },
		{ ...FRANKFURTER_RESPONSE, rates: { USD: "1.1" } },
		{ ...FRANKFURTER_RESPONSE, base: 1 },
		null,
		"rates",
	]) {
		const { source: brokenSource } = fakeSource({ responses: [broken] });
		assert.equal(
			await createCurrencyRates(brokenSource).refresh(),
			null,
			JSON.stringify(broken),
		);
	}
});

function tick() {
	return new Promise((resolve) => setTimeout(resolve, 0));
}

// Runs a lookup and waits for any late result it promised.
async function lookup(
	query: string,
	rates: ReturnType<typeof createCurrencyRates>,
) {
	const late: string[] = [];
	const now = lookupCurrencyConversion(query, rates, (result) => {
		late.push(String(shown(result)));
	});
	await new Promise((resolve) => setTimeout(resolve, 0));
	return { now: shown(now), late };
}

test("typing a query that is not a currency conversion never fetches", async () => {
	const { source, calls } = fakeSource({ responses: [FRANKFURTER_RESPONSE] });
	const rates = createCurrencyRates(source);

	for (const query of [
		"5 m to ft",
		"100 kgs to lbs",
		"2 cups to ml",
		"100 usd",
		"100 usd to e",
		"100 usd to eu",
		"usd to eur",
		"hello",
		"2+2",
		"100 abc to xyz",
	]) {
		assert.deepEqual(
			await lookup(query, rates),
			{ now: null, late: [] },
			query,
		);
	}
	assert.equal(calls.fetches, 0);
});

test("the first currency query with no cache shows its result once the rates arrive", async () => {
	const { source, calls } = fakeSource({ responses: [FRANKFURTER_RESPONSE] });
	const rates = createCurrencyRates(source);

	assert.deepEqual(await lookup("100 usd to eur", rates), {
		now: null,
		late: ["100 USD = 90.91 EUR"],
	});
	assert.equal(calls.fetches, 1);
});

test("a fresh cache answers at once, with nothing late", async () => {
	const { source, calls } = fakeSource({
		cache: { ...RATES, fetchedAt: NOW - HOUR },
	});
	const rates = createCurrencyRates(source);
	await rates.load();

	assert.deepEqual(await lookup("100 usd to eur", rates), {
		now: "100 USD = 80.00 EUR",
		late: [],
	});
	assert.equal(calls.fetches, 0);
});

test("a stale cache answers at once, then the fresh rates replace it", async () => {
	const { source, calls } = fakeSource({
		cache: { ...RATES, fetchedAt: NOW - 2 * DAY },
		responses: [FRANKFURTER_RESPONSE],
	});
	const rates = createCurrencyRates(source);
	await rates.load();

	assert.deepEqual(await lookup("100 usd to eur", rates), {
		now: "100 USD = 80.00 EUR",
		late: ["100 USD = 90.91 EUR"],
	});
	assert.equal(calls.fetches, 1);
});

test("offline with a stale cache, the last known rate shows with its date", async () => {
	const { source } = fakeSource({
		cache: { ...RATES, fetchedAt: NOW - 30 * DAY },
	});
	const rates = createCurrencyRates(source);
	await rates.load();

	const result = lookupCurrencyConversion("100 usd to eur", rates, () => {
		assert.fail("no late result while offline");
	});
	await new Promise((resolve) => setTimeout(resolve, 0));
	assert.equal(
		result?.kind === "comparison" ? result.footer : null,
		"1 USD = 0.8 EUR · ECB rate of 2026-11-25",
	);
});

test("offline with no cache, a currency query shows nothing", async () => {
	const { source, calls } = fakeSource({});
	const rates = createCurrencyRates(source);

	assert.deepEqual(await lookup("100 usd to eur", rates), {
		now: null,
		late: [],
	});
	assert.equal(calls.fetches, 1);
});
