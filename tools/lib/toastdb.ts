// The toast oracle on Windows: what Windows itself recorded, read out of the
// notification platform's own database, for tools/capture's "delivered" line.
//
// Every toast the platform accepts is stored in
// %LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db; the row
// carries the exact XML tools/notify-action.ps1 handed to
// ToastNotificationManager, so a row proves delivery reached Windows, not
// merely that the helper exited 0.
//
// The live file is held open by WpnUserService, so it is copied first, and
// the -wal and -shm files travel with it or the newest rows are missing from
// the copy. The copy is the user's whole notification history, every app
// included: it lives in a fresh temp directory for the duration of one read
// and is removed before the rows are returned.
import { Database } from 'bun:sqlite';
import { copyFileSync, existsSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PLUGIN_ID, localAppData } from './snn';

export interface ToastRow {
	id: number;
	arrived: Date;
	xml: string;
}

interface RawRow {
	Id: bigint;
	ArrivalTime: bigint;
	Payload: Uint8Array | null;
}

const FILETIME_EPOCH_MS = 11644473600000n;

function fromFileTime(ticks: bigint): Date {
	return new Date(Number(ticks / 10000n - FILETIME_EPOCH_MS));
}

/**
 * The Payload column is a BLOB the platform writes as UTF-16LE (with or
 * without a BOM); older rows can be UTF-8. Sniffed from the first bytes.
 */
function decodePayload(b: Uint8Array | null): string {
	if (!b || b.length === 0) return '';
	if (b.length >= 2 && b[0] === 0xff && b[1] === 0xfe) return new TextDecoder('utf-16le').decode(b.subarray(2));
	if (b.length >= 2 && b[1] === 0x00) return new TextDecoder('utf-16le').decode(b);
	return new TextDecoder('utf-8').decode(b);
}

// Toasts only: the table also holds tile and badge updates and this
// AUMID's own payload-less toastCondensed rows, none of which is a card.
const SQL =
	'select n.Id, n.ArrivalTime, n.Payload from Notification n ' +
	'join NotificationHandler h on n.HandlerId = h.RecordId ' +
	"where n.Type = 'toast' and h.PrimaryId = ? " +
	'order by n.ArrivalTime desc, n.Id desc limit ?';

/** The toasts this plugin delivered, newest first. */
export function toastRows(limit = 10): ToastRow[] {
	const src = join(localAppData(), 'Microsoft', 'Windows', 'Notifications', 'wpndatabase.db');
	if (!existsSync(src)) throw new Error(`no notification database at ${src}`);
	const dir = mkdtempSync(join(tmpdir(), 'snn-wpn-'));
	try {
		const copy = join(dir, 'wpndatabase.db');
		for (const ext of ['', '-wal', '-shm']) {
			if (existsSync(src + ext)) copyFileSync(src + ext, copy + ext);
		}
		const db = new Database(copy, { readonly: true, safeIntegers: true });
		try {
			return (db.query(SQL).all(PLUGIN_ID, BigInt(limit)) as RawRow[]).map((r) => ({
				id: Number(r.Id),
				arrived: fromFileTime(r.ArrivalTime),
				xml: decodePayload(r.Payload),
			}));
		} finally {
			db.close();
		}
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
}
