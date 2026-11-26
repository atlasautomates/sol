// Currency conversion for the search query: `100 usd to eur`, `€50 in gbp`.
// Rates are the ECB reference rates. parseCurrencyConversion is pure: it reads
// a query against a rates table it is given. createCurrencyRates holds that
// table, reading a cache and fetching through an injected source, so tests
// supply both and never reach the network.

import type { TemporaryResult } from "./temporaryResult.ts";

export type CurrencyRates = {
	// Every rate is units of that currency per one `base`.
	base: string;
	// The day the ECB published these rates, as YYYY-MM-DD.
	date: string;
	rates: Record<string, number>;
};

export type CachedRates = CurrencyRates & { fetchedAt: number };

export type CurrencyRatesSource = {
	readCache: () => Promise<unknown>;
	writeCache: (rates: CachedRates) => void;
	fetchLatest: () => Promise<unknown>;
	now: () => number;
};

export type CurrencyRatesProvider = ReturnType<typeof createCurrencyRates>;

// The currencies the ECB publishes. A query must name two of these, or two in
// the cached table, before Sol fetches anything.
export const ECB_CURRENCIES = [
	"AUD",
	"BRL",
	"CAD",
	"CHF",
	"CNY",
	"CZK",
	"DKK",
	"EUR",
	"GBP",
	"HKD",
	"HUF",
	"IDR",
	"ILS",
	"INR",
	"ISK",
	"JPY",
	"KRW",
	"MXN",
	"MYR",
	"NOK",
	"NZD",
	"PHP",
	"PLN",
	"RON",
	"SEK",
	"SGD",
	"THB",
	"TRY",
	"USD",
	"ZAR",
];

const CURRENCY_SYMBOLS: Record<string, string> = {
	$: "USD",
	"€": "EUR",
	"£": "GBP",
	"¥": "JPY",
};

// ISO 4217 currencies without minor units, among the ECB's.
const WHOLE_UNIT_CURRENCIES = new Set(["JPY", "KRW", "ISK"]);

const RATES_MAX_AGE_MS = 24 * 60 * 60 * 1000;
const RETRY_AFTER_FAILURE_MS = 60 * 60 * 1000;

const CURRENCY_QUERY =
	/^(?<before>[$€£¥])?\s*(?<amount>\d+(?:\.\d+)?|\.\d+)\s*(?<from>[$€£¥]|[a-z]{3})?\s+(?:to|in)\s+(?<to>[$€£¥]|[a-z]{3})$/i;

type CurrencyQuery = { amount: number; from: string; to: string };

function currencyCode(token: string | undefined) {
	if (token == null) {
		return null;
	}
	return CURRENCY_SYMBOLS[token] ?? token.toUpperCase();
}

// The amount and the two currencies a query names, when both are in `codes`.
function parseCurrencyQuery(
	query: string,
	codes: ReadonlySet<string>,
): CurrencyQuery | null {
	const normalized = query.trim().replace(/,/g, "").replace(/\s+/g, " ");
	const groups = normalized.match(CURRENCY_QUERY)?.groups;
	if (groups == null) {
		return null;
	}

	const before = currencyCode(groups.before);
	const after = currencyCode(groups.from);
	if (before != null && after != null && before !== after) {
		return null;
	}

	const from = before ?? after;
	const to = currencyCode(groups.to);
	if (from == null || to == null || !codes.has(from) || !codes.has(to)) {
		return null;
	}

	return { amount: Number.parseFloat(groups.amount), from, to };
}

function tableCodes(rates: CurrencyRates) {
	return new Set([rates.base, ...Object.keys(rates.rates)]);
}

function rateOf(rates: CurrencyRates, code: string) {
	return code === rates.base ? 1 : rates.rates[code];
}

function formatMoney(value: number, code: string) {
	return value.toFixed(WHOLE_UNIT_CURRENCIES.has(code) ? 0 : 2);
}

function formatRate(value: number) {
	return Number(value.toPrecision(6)).toString();
}

// The conversion a query asks for, or null when it names a currency missing
// from `rates` (so `5 m to ft` is never a currency) or there are no rates.
export function parseCurrencyConversion(
	query: string,
	rates: CurrencyRates | null,
): TemporaryResult | null {
	if (rates == null) {
		return null;
	}

	const parsed = parseCurrencyQuery(query, tableCodes(rates));
	if (parsed == null) {
		return null;
	}

	const rate = rateOf(rates, parsed.to) / rateOf(rates, parsed.from);
	return {
		kind: "comparison",
		left: { label: parsed.from, value: formatRate(parsed.amount) },
		right: {
			label: parsed.to,
			value: formatMoney(parsed.amount * rate, parsed.to),
		},
		footer: `1 ${parsed.from} = ${formatRate(rate)} ${parsed.to} · ECB rate of ${rates.date}`,
	};
}

// A frankfurter.app response or a cache file, read as a rates table. The base
// currency joins the table at 1, so the table lists every code it converts.
function readRates(value: unknown): CurrencyRates | null {
	if (value == null || typeof value !== "object") {
		return null;
	}

	const { base, date, rates } = value as Record<string, unknown>;
	if (
		typeof base !== "string" ||
		!/^[A-Z]{3}$/.test(base) ||
		typeof date !== "string" ||
		!/^\d{4}-\d{2}-\d{2}$/.test(date) ||
		rates == null ||
		typeof rates !== "object"
	) {
		return null;
	}

	const table: Record<string, number> = {};
	for (const [code, rate] of Object.entries(rates)) {
		if (
			!/^[A-Z]{3}$/.test(code) ||
			typeof rate !== "number" ||
			!Number.isFinite(rate) ||
			rate <= 0
		) {
			return null;
		}
		table[code] = rate;
	}

	return { base, date, rates: { ...table, [base]: 1 } };
}

function readCachedRates(value: unknown): CachedRates | null {
	const rates = readRates(value);
	const fetchedAt = (value as { fetchedAt?: unknown } | null)?.fetchedAt;
	if (rates == null || typeof fetchedAt !== "number") {
		return null;
	}
	return { ...rates, fetchedAt };
}

export function createCurrencyRates(source: CurrencyRatesSource) {
	let cached: CachedRates | null = null;
	let loading: Promise<void> | null = null;
	let fetching: Promise<CurrencyRates | null> | null = null;
	let lastFailureAt = Number.NEGATIVE_INFINITY;

	function load() {
		loading ??= source
			.readCache()
			.then((value) => {
				cached ??= readCachedRates(value);
			})
			.catch(() => {});
		return loading;
	}

	async function fetchRates(): Promise<CurrencyRates | null> {
		try {
			const rates = readRates(await source.fetchLatest());
			if (rates == null) {
				throw new Error("the rates response is not a rates table");
			}
			cached = { ...rates, fetchedAt: source.now() };
			source.writeCache(cached);
		} catch {
			lastFailureAt = source.now();
		}
		return cached;
	}

	function isFresh(rates: CachedRates) {
		const age = source.now() - rates.fetchedAt;
		return age >= 0 && age < RATES_MAX_AGE_MS;
	}

	return {
		load,

		// The rates on hand now, fresh or stale, or null before any arrive.
		current(): CurrencyRates | null {
			return cached;
		},

		// The rates once any fetch they need is done. Fetches only when the
		// cache is missing or a day old, and not within an hour of a failure.
		async refresh(): Promise<CurrencyRates | null> {
			await load();
			if (cached != null && isFresh(cached)) {
				return cached;
			}
			if (source.now() - lastFailureAt < RETRY_AFTER_FAILURE_MS) {
				return cached;
			}
			fetching ??= fetchRates().finally(() => {
				fetching = null;
			});
			return fetching;
		},
	};
}

// The answer to a currency query from the rates on hand, or null. When the
// rates are missing or stale, it refreshes them and passes `onLate` the answer
// from the new rates. A query that does not name two known currencies returns
// null and fetches nothing.
export function lookupCurrencyConversion(
	query: string,
	provider: CurrencyRatesProvider,
	onLate: (result: TemporaryResult) => void,
): TemporaryResult | null {
	const onHand = provider.current();
	const codes = new Set([
		...ECB_CURRENCIES,
		...(onHand == null ? [] : tableCodes(onHand)),
	]);
	if (parseCurrencyQuery(query, codes) == null) {
		return null;
	}

	void provider.refresh().then((rates) => {
		if (rates == null || rates === onHand) {
			return;
		}
		const late = parseCurrencyConversion(query, rates);
		if (late != null) {
			onLate(late);
		}
	});

	return parseCurrencyConversion(query, onHand);
}
