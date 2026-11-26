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

// How many digits a converted value shows. A value of 1 or more shows up to
// six decimals, and a smaller one six significant digits. Either way it keeps
// at least as many significant digits as the amount typed (1.0000001 kg is
// 1000.0001 g), and at most 12, which hides float noise (0.3 cm is
// 3.0000000000000004 mm in floating point). Whole digits are never rounded.
export const SHOWN_DIGITS = 6;
const MAX_SIGNIFICANT_DIGITS = 12;

export function formatConvertedValue(value: number, typedDigits = 1) {
	if (value === 0) {
		return "0";
	}
	if (!Number.isFinite(value)) {
		return value.toString();
	}

	const wholeDigits = Math.floor(Math.log10(Math.abs(value))) + 1;
	const shown = Math.max(SHOWN_DIGITS + Math.max(wholeDigits, 0), typedDigits);
	const digits = Math.min(
		shown,
		Math.max(MAX_SIGNIFICANT_DIGITS, wholeDigits),
		100,
	);
	return Number(value.toPrecision(digits)).toString();
}

// The significant digits in an amount as typed: 3 for 0.000123, 8 for
// 1.0000001, 4 for 1,500.
export function typedDigits(amountText: string) {
	return Math.max(1, amountText.replace(/\D/g, "").replace(/^0+/, "").length);
}
