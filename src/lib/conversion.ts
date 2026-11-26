// What unit and currency conversion share: how a query is split, how an
// amount is read, and how a converted value shows.

// Conversion queries are short. Anything longer is a paste, and is not
// parsed at all, so no regex runs over it.
export const MAX_CONVERSION_QUERY_LENGTH = 100;

// Between the two units or currencies: `to` or `in`, in any case.
export const CONVERSION_SEPARATOR = "(?:to|in)";

// An amount as typed: 12, -2.5, .5, 1,5 (decimal comma), 1,500 or 1,000,000
// (thousands), 1.234,5 (dots group thousands before a decimal comma).
export const AMOUNT =
	"-?(?:\\d{1,3}(?:\\.\\d{3})+,\\d+|\\d{1,3}(?:,\\d{3})+(?:\\.\\d+)?|\\d+(?:[.,]\\d+)?|[.,]\\d+)";

const WHOLE_AMOUNT = new RegExp(`^${AMOUNT}$`);

// The value of an amount AMOUNT matched. A comma before exactly three digits
// groups thousands, as in English; any other comma between digits is a
// decimal comma, and 1.234,5 reads as the calculator reads it. The
// calculator alone reads 1,500 as 1.5: a conversion amount is more often a
// grouped whole number.
export function readAmount(text: string): number | null {
	if (!WHOLE_AMOUNT.test(text)) {
		return null;
	}

	let plain: string;
	if (/^-?\d{1,3}(?:\.\d{3})+,\d+$/.test(text)) {
		plain = text.replace(/\./g, "").replace(",", ".");
	} else if (/^-?\d{1,3}(?:,\d{3})+(?:\.\d+)?$/.test(text)) {
		plain = text.replace(/,/g, "");
	} else {
		plain = text.replace(",", ".");
	}

	const value = Number(plain);
	return Number.isFinite(value) ? value : null;
}

// convert-units' factors carry about six significant digits (453.592 g per
// pound, 3.28084 ft per metre), so more digits than that are noise: 5 ft is
// 152.399995 cm to convert-units. Digits left of the decimal point are kept,
// so a large whole number is never rounded.
const CONVERTED_VALUE_SIGNIFICANT_DIGITS = 6;

export function formatConvertedValue(value: number) {
	if (!Number.isFinite(value) || value === 0) {
		return value.toString();
	}

	const wholeDigits = Math.floor(Math.log10(Math.abs(value))) + 1;
	const digits = Math.min(
		100,
		Math.max(CONVERTED_VALUE_SIGNIFICANT_DIGITS, wholeDigits),
	);
	return Number(value.toPrecision(digits)).toString();
}
