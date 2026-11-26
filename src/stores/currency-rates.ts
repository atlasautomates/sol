import { createCurrencyRates } from "lib/currency";
import { readPersistedStore, writePersistedStore } from "./persisted-config";

// The ECB reference rates, per euro, from Frankfurter (api.frankfurter.app
// redirects here). The request carries no query, no cookies and no headers of
// Sol's: nothing about the user.
const RATES_URL = "https://api.frankfurter.dev/v1/latest";
const RATES_TIMEOUT_MS = 6000;

async function fetchLatestRates(): Promise<unknown> {
	const controller = new AbortController();
	const timer = setTimeout(() => controller.abort(), RATES_TIMEOUT_MS);
	try {
		const response = await fetch(RATES_URL, {
			credentials: "omit",
			signal: controller.signal,
		});
		if (!response.ok) {
			throw new Error(`${RATES_URL} answered ${response.status}`);
		}
		return await response.json();
	} finally {
		clearTimeout(timer);
	}
}

// Cached in state.json under ~/.config/sol, beside the clipboard and the
// emoji picker's state.
export const currencyRates = createCurrencyRates({
	readCache: () => readPersistedStore("currencyRates"),
	writeCache: (cache) => {
		writePersistedStore("currencyRates", cache);
	},
	fetchLatest: fetchLatestRates,
	now: () => Date.now(),
});
