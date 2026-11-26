// An answer that exists only for the current query: a calculation, a
// conversion, this machine's IP address, a flight.
export type TemporaryResult =
	| {
			kind: "text";
			value: string;
			secondary?: string;
	  }
	| {
			kind: "comparison";
			left: { label: string; value: string };
			right: { label: string; value: string };
			footer?: string;
	  }
	| {
			kind: "flight";
			flight: string;
			status?: string;
			departureTime?: string;
			arrivalTime?: string;
			terminal?: string;
			gate?: string;
	  };
