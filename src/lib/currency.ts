// Currency conversion for the search query: `100 usd to eur`, `€50 in gbp`.
// Rates are the ECB reference rates. parseCurrencyConversion is pure: it reads
// a query against a rates table it is given. createCurrencyRates holds that
// table, reading a cache and fetching through an injected source, so tests
// supply both and never reach the network.

import {
	AMOUNT,
	CONVERSION_SEPARATOR,
	MAX_CONVERSION_QUERY_LENGTH,
	readAmount,
	SHOWN_DIGITS,
} from "./conversion.ts";
import type { TemporaryResult } from "./temporaryResult.ts";

export type CurrencyRates = {
	// Every rate is units of that currency per one `base`. The table lists
	// the base too, at 1.
	base: string;
	// The day the ECB published these rates, as YYYY-MM-DD.
	date: string;
	rates: Record<string, number>;
};

// What the cache holds: the last good table, when it was fetched, and when a
// fetch last failed, so a restart keeps the wait before the next try.
export type RatesCache = Partial<CurrencyRates> & {
	fetchedAt?: number;
	failedAt?: number;
};

export type CurrencyRatesSource = {
	readCache: () => Promise<unknown>;
	writeCache: (cache: RatesCache) => void;
	fetchLatest: () => Promise<unknown>;
	now: () => number;
};

export type CurrencyRatesProvider = ReturnType<typeof createCurrencyRates>;

// The currencies the ECB publishes. A query must name two of these before Sol
// fetches anything, and a table keeps only these.
export const ECB_CURRENCIES: ReadonlySet<string> = new Set([
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
]);

// A table with fewer codes, or without USD and GBP, is a broken response.
const MIN_TABLE_CODES = 10;
const REQUIRED_CODES = ["USD", "GBP"];

// Symbols and words for a currency. `pound` is a currency only here: the
// unit parser runs first and reads `10 pounds to kg` as mass.
const CURRENCY_NAMES: Record<string, string> = {
	$: "USD",
	"€": "EUR",
	"£": "GBP",
	"¥": "JPY",
	dollar: "USD",
	dollars: "USD",
	euro: "EUR",
	euros: "EUR",
	pound: "GBP",
	pounds: "GBP",
	yen: "JPY",
	franc: "CHF",
	francs: "CHF",
};

// ISO 4217 currencies without minor units, among the ECB's.
const WHOLE_UNIT_CURRENCIES = new Set(["JPY", "KRW", "ISK"]);

// Past this, float arithmetic loses the cents.
const MAX_AMOUNT = 1e12;

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;
const RETRY_AFTER_FAILURE_MS = HOUR_MS;

const CURRENCY_QUERY = new RegExp(
	`^(?<before>[$€£¥])?\\s*(?<amount>${AMOUNT})\\s*(?<from>[$€£¥]|[a-z]+)?\\s+${CONVERSION_SEPARATOR}\\s+(?<to>[$€£¥]|[a-z]+)$`,
	"i",
);

type CurrencyQuery = {
	amount: number;
	amountText: string;
	from: string;
	to: string;
};

function currencyCode(token: string | undefined) {
	if (token == null) {
		return null;
	}
	const lower = token.toLowerCase();
	return (
		CURRENCY_NAMES[lower] ?? (lower.length === 3 ? token.toUpperCase() : null)
	);
}

// The amount and the two currencies a query names, when both are in `codes`.
function parseCurrencyQuery(
	query: string,
	codes: ReadonlySet<string>,
): CurrencyQuery | null {
	if (query.length > MAX_CONVERSION_QUERY_LENGTH) {
		return null;
	}

	const groups = query
		.trim()
		.replace(/\s+/g, " ")
		.match(CURRENCY_QUERY)?.groups;
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

	const amount = readAmount(groups.amount);
	if (amount == null || Math.abs(amount) >= MAX_AMOUNT) {
		return null;
	}

	return { amount, amountText: groups.amount, from, to };
}

// Cents, or none for yen; an amount under a cent shows three significant
// digits (1 IDR is 0.0000495 EUR), written out rather than as 4.95e-5.
function formatMoney(value: number, code: string) {
	const cents = WHOLE_UNIT_CURRENCIES.has(code) ? 0 : 2;
	const magnitude = Math.abs(value);
	if (magnitude === 0 || magnitude >= 10 ** -cents) {
		return value.toFixed(cents);
	}
	const decimals = Math.min(20, 2 - Math.floor(Math.log10(magnitude)));
	return Number(value.toFixed(decimals)).toFixed(decimals).replace(/0+$/, "");
}

function formatRate(value: number) {
	const rounded = Number(value.toPrecision(SHOWN_DIGITS));
	return rounded >= 1e-6
		? rounded.toString()
		: rounded.toFixed(20).replace(/0+$/, "");
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

	const parsed = parseCurrencyQuery(query, new Set(Object.keys(rates.rates)));
	if (parsed == null) {
		return null;
	}

	const rate = rates.rates[parsed.to] / rates.rates[parsed.from];
	return {
		kind: "comparison",
		left: { label: parsed.from, value: parsed.amountText },
		right: {
			label: parsed.to,
			value: formatMoney(parsed.amount * rate, parsed.to),
		},
		footer: `1 ${parsed.from} = ${formatRate(rate)} ${parsed.to} · ECB rate of ${rates.date}`,
	};
}

// A real calendar day, YYYY-MM-DD, no later than tomorrow.
function isRatesDate(date: unknown, now: number): date is string {
	const match =
		typeof date === "string" && /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
	if (!match) {
		return false;
	}
	const [year, month, day] = match.slice(1).map(Number);
	const time = Date.UTC(year, month - 1, day);
	const parsed = new Date(time);
	return (
		parsed.getUTCFullYear() === year &&
		parsed.getUTCMonth() === month - 1 &&
		parsed.getUTCDate() === day &&
		time <= now + DAY_MS
	);
}

// A frankfurter response or a cache, read as a rates table: ECB codes only,
// with the base at 1. Null unless it has the codes a full table has.
function readRates(value: unknown, now: number): CurrencyRates | null {
	if (value == null || typeof value !== "object") {
		return null;
	}

	const { base, date, rates } = value as Record<string, unknown>;
	if (
		typeof base !== "string" ||
		!ECB_CURRENCIES.has(base) ||
		!isRatesDate(date, now) ||
		rates == null ||
		typeof rates !== "object" ||
		Array.isArray(rates)
	) {
		return null;
	}

	const table: Record<string, number> = { [base]: 1 };
	for (const [code, rate] of Object.entries(rates)) {
		if (typeof rate !== "number" || !Number.isFinite(rate) || rate <= 0) {
			return null;
		}
		if (ECB_CURRENCIES.has(code)) {
			table[code] = rate;
		}
	}

	if (
		Object.keys(table).length < MIN_TABLE_CODES ||
		REQUIRED_CODES.some((code) => table[code] == null)
	) {
		return null;
	}

	return { base, date, rates: table };
}

function readTimestamp(value: unknown, key: "fetchedAt" | "failedAt") {
	const time = (value as Record<string, unknown> | null)?.[key];
	return typeof time === "number" && Number.isFinite(time) ? time : null;
}

export function createCurrencyRates(source: CurrencyRatesSource) {
	let table: CurrencyRates | null = null;
	let fetchedAt: number | null = null;
	let failedAt: number | null = null;
	let fetching: Promise<CurrencyRates | null> | null = null;

	const loading = source
		.readCache()
		.then((value) => {
			const cachedFetchedAt = readTimestamp(value, "fetchedAt");
			const cachedTable = readRates(value, source.now());
			if (cachedTable != null && cachedFetchedAt != null) {
				table = cachedTable;
				fetchedAt = cachedFetchedAt;
			}
			failedAt = readTimestamp(value, "failedAt");
		})
		.catch(() => {});

	function cacheRecord(): RatesCache {
		return table == null ? {} : { ...table, fetchedAt: fetchedAt ?? undefined };
	}

	async function fetchRates(): Promise<CurrencyRates | null> {
		const startedAt = source.now();
		let fetched: CurrencyRates | null = null;
		try {
			fetched = readRates(await source.fetchLatest(), startedAt);
		} catch {
			fetched = null;
		}

		if (fetched == null) {
			failedAt = source.now();
			source.writeCache({ ...cacheRecord(), failedAt });
		} else {
			table = fetched;
			fetchedAt = source.now();
			failedAt = null;
			source.writeCache(cacheRecord());
		}
		return table;
	}

	function isFresh() {
		const age = fetchedAt == null ? -1 : source.now() - fetchedAt;
		return age >= 0 && age < DAY_MS;
	}

	return {
		// The rates on hand now, fresh or stale, or null before any arrive.
		current(): CurrencyRates | null {
			return table;
		},

		// The rates once any fetch they need is done. Fetches only when the
		// cache is missing or a day old, and not within an hour of a failure.
		async refresh(): Promise<CurrencyRates | null> {
			await loading;
			if (table != null && isFresh()) {
				return table;
			}
			if (
				failedAt != null &&
				source.now() - failedAt < RETRY_AFTER_FAILURE_MS
			) {
				return table;
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
// from the new rates. A query that does not name two ECB currencies returns
// null and fetches nothing.
export function lookupCurrencyConversion(
	query: string,
	provider: CurrencyRatesProvider,
	onLate: (result: TemporaryResult) => void,
): TemporaryResult | null {
	if (parseCurrencyQuery(query, ECB_CURRENCIES) == null) {
		return null;
	}

	const onHand = provider.current();
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
