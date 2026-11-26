// Currency conversion for the search query. Implemented in the next commit.
export type CurrencyRates = {
	base: string;
	date: string;
	rates: Record<string, number>;
};
export type CachedRates = CurrencyRates & { fetchedAt: number };
export function parseCurrencyConversion(_query: string, _rates: CurrencyRates | null): any {
	return null;
}
export function createCurrencyRates(_source: any): any {
	return { load: async () => {}, refresh: async () => null, current: () => null };
}
export function lookupCurrencyConversion(_q: string, _r: any, _onLate: any): any {
	return null;
}
