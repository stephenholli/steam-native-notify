import { firstFiber } from './fiber';
import { fieldsForType } from './generated/notifications';
import type { PbValue, ServerNotification } from './routes';

/**
 * "React tree -> typed notification", in one place.
 *
 * Steam attaches its own decoded notification object to the toast's React
 * tree: `{ eType, eSource, data, ... }`. Client-sourced data is a Closure
 * protobuf whose positional array is decoded with the generated schema;
 * server-sourced data is a rollup whose `item.body_data` is JSON.
 */
export type DecodedNotification =
	| { source: 'client'; type: number; fields: Record<string, PbValue> }
	| { source: 'server'; type: number; server: ServerNotification };

/** eSource on Steam's notification object: which of the two systems produced it. */
const SOURCE_SERVER = 2;

let foundBrowserInfo: unknown = null;

export function takeToastBrowserInfo(): unknown {
	const value = foundBrowserInfo;
	foundBrowserInfo = null;
	return value;
}

/**
 * The notification Steam attached to the toast, read out of the React tree.
 *
 * Preferred over the notification feed because it sees more: an incoming voice
 * chat renders as `notificationtoasts_10000_desktop` and produces no feed
 * event at all. Returns null when the tree cannot be read; the toast is still
 * delivered, just without the log detail.
 */
export function notificationFromToast(win: Window): DecodedNotification | null {
	// Declared outside the try: a throw on a fiber ABOVE the notification must
	// not discard an already-decoded result.
	let decoded: DecodedNotification | null = null;
	try {
		const doc = win.document;
		if (!doc) return null;

		let fiber: any = firstFiber(doc);
		if (!fiber) return null;
		for (let depth = 0; fiber && depth < 30; depth++) {
			const props = fiber.memoizedProps ?? fiber.pendingProps;
			if (!foundBrowserInfo) {
				try {
					const browserInfo =
						props?.browserInfo ??
						props?.params?.browserInfo ??
						props?.value?.params?.browserInfo ??
						props?.value?.browserInfo;
					if (browserInfo && typeof browserInfo === 'object') foundBrowserInfo = browserInfo;
				} catch {
					/* hostile context getter; keep walking */
				}
			}
			const notification = props?.notification;
			if (!decoded && notification && typeof notification === 'object') {
				const type = Number((notification as any).eType);
				const source = Number((notification as any).eSource);
				const data = (notification as any).data;

				if (source === SOURCE_SERVER) {
					let body: Record<string, unknown> | null = null;
					try {
						const raw = data?.item?.body_data;
						if (typeof raw === 'string' && raw) body = JSON.parse(raw);
					} catch {
						/* an unparseable body logs as null, and the raw dump in the log shows why */
					}
					decoded = {
						source: 'server',
						type,
						server: {
							type: Number(data?.type),
							body,
							url: typeof data?.url === 'string' ? data.url : undefined,
						},
					};
				} else {
					const fields: Record<string, PbValue> = {};
					const schema = fieldsForType(type);
					const array = data?.array;
					const offset = typeof data?.arrayIndexOffset_ === 'number' ? data.arrayIndexOffset_ : -1;
					if (schema && Array.isArray(array)) {
						for (const [num, field] of Object.entries(schema)) {
							const value = array[Number(num) + offset];
							if (value !== undefined && value !== null) fields[field.name] = value as PbValue;
						}
					}
					decoded = { source: 'client', type, fields };
				}
			}
			fiber = fiber.return;
		}
		return decoded;
	} catch {
		/* a toast that cannot be fully read still gets delivered; whatever
		   decoded before the throw survives */
	}
	return decoded;
}
