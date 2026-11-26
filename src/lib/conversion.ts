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
