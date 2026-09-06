import { dlog } from './log';
import { clickEnvelopeFromSteamUrl } from './click';
import { dispatchClick } from './clickbridge';

/**
 * The Windows click transport: Steam's own steam:// dispatch.
 *
 * A desktop notification cannot reach this plugin directly on Windows.
 * Measured on Windows 11 (docs/platforms.md): a toast activates
 * `activationType="protocol"` only for schemes Windows already knows --
 * `ms-settings:`, `http:`, and `steam:` all launch; a scheme this plugin
 * registers itself never does, under every registration tried. Steam's own
 * scheme is therefore the way in, and Steam hands a steam:// URL to the
 * client's JS, where this plugin lives.
 *
 * `RegisterForRunSteamURL` takes any section name (Millennium registers
 * `millennium` the same way), so a Windows toast carries a versioned envelope
 * in `steam://snn/click/<base64url>`. Windows keeps that URI with notification
 * history, so its verified catalog fallback survives a Steam restart.
 *
 * Linux keeps the click file: notify-send hands the click back to a helper
 * this plugin owns, which needs no round trip through Steam. Registering
 * here is additive on every platform -- a second door to the same stash,
 * never a replacement for the bridge.
 */
const URL_SECTION = 'snn';

interface Unregisterable {
	unregister(): void;
}

interface SteamUrlApi {
	RegisterForRunSteamURL(section: string, callback: (n: number, url: string) => void): Unregisterable;
}

/**
 * Never throws: a failed registration must leave delivery untouched, and an
 * older client without the API simply has no Windows click path.
 */
export function registerSteamUrlClicks(): Unregisterable | null {
	try {
		const api = (Reflect.get(globalThis, 'SteamClient') as { URL?: SteamUrlApi } | undefined)?.URL;
		if (typeof api?.RegisterForRunSteamURL !== 'function') {
			dlog('steam-url: RegisterForRunSteamURL unavailable; no steam:// click path');
			return null;
		}
		const registration = api.RegisterForRunSteamURL(URL_SECTION, (_n: number, url: string) => {
			try {
				const envelope = clickEnvelopeFromSteamUrl(String(url ?? ''));
				if (!envelope) {
					dlog(`steam-url: ignored ${String(url).slice(0, 120)}`);
					return;
				}
				dlog(`steam-url: click token=${envelope.token.slice(0, 8)}`);
				void dispatchClick(envelope);
			} catch (e) {
				dlog(`steam-url handler failed: ${(e as Error)?.message ?? e}`);
			}
		});
		dlog(`steam-url: registered steam://${URL_SECTION}/click/<payload>`);
		return registration;
	} catch (e) {
		dlog(`steam-url: registration failed: ${(e as Error)?.message ?? e}`);
		return null;
	}
}
