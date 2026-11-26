import assert from "node:assert/strict";
import { test } from "node:test";
import {
	type CurrencyRates,
	createCurrencyRates,
	lookupCurrencyConversion,
	parseCurrencyConversion,
	type RatesCache,
} from "./currency.ts";

// Round numbers, so expected results are easy to check by hand.
const RATES: CurrencyRates = {
	base: "EUR",
	date: "2026-11-25",
	rates: {
		EUR: 1,
		USD: 1.25,
		GBP: 0.8,
		JPY: 160,
		IDR: 20187.03,
		CHF: 0.95,
		AUD: 1.6,
		CAD: 1.5,
		NOK: 10,
		SEK: 11,
	},
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
		["100 brl to eur", null],
		["100 usd to xyz", null],
		["5 m to ft", null],
		["100 kgs to lbs", null],
		["100 usd", null],
		["usd to eur", null],
		["100 usd to e", null],
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

test("amounts under a cent show three significant digits", () => {
	converts([
		["1 idr to eur", "1 IDR = 0.0000495 EUR"],
		["100 idr to eur", "100 IDR = 0.00495 EUR"],
		["1000 idr to eur", "1000 IDR = 0.05 EUR"],
		["0 usd to eur", "0 USD = 0.00 EUR"],
	]);
	const result = parseCurrencyConversion("1 idr to eur", RATES);
	assert.equal(
		result?.kind === "comparison" ? result.footer : null,
		"1 IDR = 0.0000495368 EUR · ECB rate of 2026-11-25",
	);
});

test("amounts of a trillion or more are not converted", () => {
	converts([
		["999999999999 usd to eur", "999999999999 USD = 799999999999.20 EUR"],
		["1000000000000 usd to eur", null],
		["100000000000000000000000000 usd to jpy", null],
	]);
});

test("currency words: dollars, euros, pounds, yen and francs", () => {
	converts([
		["5 dollars to euros", "5 USD = 4.00 EUR"],
		["1 dollar in euro", "1 USD = 0.80 EUR"],
		["10 pounds to usd", "10 GBP = 15.63 USD"],
		["10 pound to €", "10 GBP = 12.50 EUR"],
		["1001 yen to dollars", "1001 JPY = 7.82 USD"],
		["10 francs to eur", "10 CHF = 10.53 EUR"],
		["10 pounds to kg", null],
		["10 dollars", null],
	]);
});

test("whole-unit currencies drop the decimal point, and huge results drop the cents", () => {
	converts([
		["0.0062475 eur to jpy", "0.0062475 EUR = 1 JPY"],
		["0.001 eur to jpy", "0.001 EUR = 0.16 JPY"],
		["999999999999 usd to idr", "999999999999 USD = 16149624000000000 IDR"],
		["999999999999 usd to eur", "999999999999 USD = 799999999999.20 EUR"],
	]);
});

// A fake rates source: an in-memory cache file and a scripted network.
function fakeSource(options: {
	cache?: unknown;
	responses?: Array<unknown | Error>;
	now?: number;
}) {
	const calls = { fetches: 0, writes: [] as RatesCache[] };
	const responses = [...(options.responses ?? [])];
	const clock = { now: options.now ?? NOW };
	const source = {
		readCache: async () => options.cache ?? null,
		writeCache: (rates: RatesCache) => {
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
	rates: {
		AUD: 1.654,
		CAD: 1.5617,
		CHF: 0.9153,
		CNY: 7.3096,
		GBP: 0.85,
		JPY: 175,
		NOK: 10.718,
		PLN: 4.4838,
		SEK: 11.2025,
		USD: 1.1,
	},
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
			rates: { ...FRANKFURTER_RESPONSE.rates, EUR: 1 },
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
	assert.deepEqual(calls.writes, [
		{ ...RATES, fetchedAt: NOW - 3 * DAY, failedAt: NOW },
	]);

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

test("a response or cache that is not a full ECB table is ignored, and counts as a failed fetch", async () => {
	const { source, calls } = fakeSource({
		cache: { message: "not rates" },
		responses: [{ message: "not found" }],
	});
	const rates = createCurrencyRates(source);

	assert.equal(await rates.refresh(), null);
	assert.equal(calls.fetches, 1);
	assert.deepEqual(calls.writes, [{ failedAt: NOW }]);

	const { USD: _usd, ...withoutUsd } = FRANKFURTER_RESPONSE.rates;
	const { GBP: _gbp, ...withoutGbp } = FRANKFURTER_RESPONSE.rates;
	for (const broken of [
		{ ...FRANKFURTER_RESPONSE, date: "yesterday" },
		{ ...FRANKFURTER_RESPONSE, date: "2026-02-30" },
		{ ...FRANKFURTER_RESPONSE, date: "2026-11-28" },
		{ ...FRANKFURTER_RESPONSE, rates: {} },
		{ ...FRANKFURTER_RESPONSE, rates: [] },
		{ ...FRANKFURTER_RESPONSE, rates: { USD: 1.1, GBP: 0.85 } },
		{ ...FRANKFURTER_RESPONSE, rates: withoutUsd },
		{ ...FRANKFURTER_RESPONSE, rates: withoutGbp },
		{
			...FRANKFURTER_RESPONSE,
			rates: { ...FRANKFURTER_RESPONSE.rates, USD: -1 },
		},
		{
			...FRANKFURTER_RESPONSE,
			rates: { ...FRANKFURTER_RESPONSE.rates, USD: "1.1" },
		},
		{ ...FRANKFURTER_RESPONSE, base: 1 },
		{ ...FRANKFURTER_RESPONSE, base: "XYZ" },
		null,
		"rates",
	]) {
		const { source: brokenSource, calls: brokenCalls } = fakeSource({
			responses: [broken],
		});
		assert.equal(
			await createCurrencyRates(brokenSource).refresh(),
			null,
			JSON.stringify(broken),
		);
		assert.deepEqual(brokenCalls.writes, [{ failedAt: NOW }]);
	}

	// Tomorrow's date is fine: the ECB's day can be ahead of the clock here.
	const { source: aheadSource } = fakeSource({
		responses: [{ ...FRANKFURTER_RESPONSE, date: "2026-11-27" }],
	});
	assert.equal(
		(await createCurrencyRates(aheadSource).refresh())?.date,
		"2026-11-27",
	);
});

test("codes outside the ECB's list are dropped from the table", async () => {
	const { source } = fakeSource({
		responses: [
			{
				...FRANKFURTER_RESPONSE,
				rates: { ...FRANKFURTER_RESPONSE.rates, THE: 2, END: 3 },
			},
		],
	});
	const rates = await createCurrencyRates(source).refresh();

	assert.equal(rates?.rates.THE, undefined);
	assert.equal(parseCurrencyConversion("2 the to end", rates), null);
	assert.equal(
		shown(parseCurrencyConversion("2 usd to eur", rates)),
		"2 USD = 1.82 EUR",
	);
});

test("a failed fetch is remembered across a restart", async () => {
	const stale = { ...RATES, fetchedAt: NOW - 3 * DAY };
	const first = fakeSource({ cache: stale });
	await createCurrencyRates(first.source).refresh();
	assert.deepEqual(first.calls.writes, [{ ...stale, failedAt: NOW }]);

	const restarted = fakeSource({
		cache: first.calls.writes[0],
		responses: [FRANKFURTER_RESPONSE],
		now: NOW + HOUR - 1,
	});
	const rates = createCurrencyRates(restarted.source);
	assert.equal((await rates.refresh())?.date, "2026-11-25");
	assert.equal(restarted.calls.fetches, 0);

	restarted.clock.now = NOW + HOUR;
	assert.equal((await rates.refresh())?.date, "2026-11-26");
	assert.equal(restarted.calls.fetches, 1);
	assert.deepEqual(restarted.calls.writes, [
		{
			base: "EUR",
			date: "2026-11-26",
			rates: { ...FRANKFURTER_RESPONSE.rates, EUR: 1 },
			fetchedAt: NOW + HOUR,
		},
	]);
});

test("a failed fetch with no cache is remembered too", async () => {
	const first = fakeSource({});
	await createCurrencyRates(first.source).refresh();
	assert.deepEqual(first.calls.writes, [{ failedAt: NOW }]);

	const restarted = fakeSource({
		cache: { failedAt: NOW },
		responses: [FRANKFURTER_RESPONSE],
		now: NOW + 10 * 60 * 1000,
	});
	assert.equal(await createCurrencyRates(restarted.source).refresh(), null);
	assert.equal(restarted.calls.fetches, 0);
});

test("a failure time in the future does not block fetching", async () => {
	const { source, calls } = fakeSource({
		cache: { ...RATES, fetchedAt: NOW - 3 * DAY, failedAt: NOW + DAY },
		responses: [FRANKFURTER_RESPONSE],
	});

	assert.equal(
		(await createCurrencyRates(source).refresh())?.date,
		"2026-11-26",
	);
	assert.equal(calls.fetches, 1);
});

test("the base currency is 1, whatever the response says", async () => {
	const { source } = fakeSource({
		responses: [
			{
				...FRANKFURTER_RESPONSE,
				rates: { ...FRANKFURTER_RESPONSE.rates, EUR: 2 },
			},
		],
	});
	const rates = await createCurrencyRates(source).refresh();

	assert.equal(rates?.rates.EUR, 1);
	assert.equal(
		shown(parseCurrencyConversion("2 usd to eur", rates)),
		"2 USD = 1.82 EUR",
	);
});

test("a cache that cannot be written still answers from the fetched rates", async () => {
	const { source } = fakeSource({ responses: [FRANKFURTER_RESPONSE] });
	const rates = createCurrencyRates({
		...source,
		writeCache: () => {
			throw new Error("disk full");
		},
	});

	assert.deepEqual(await lookup("100 usd to eur", rates), {
		now: null,
		late: ["100 USD = 90.91 EUR"],
	});
	assert.equal(rates.current()?.date, "2026-11-26");
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
	await tick();

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
	await tick();

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
	await tick();

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
