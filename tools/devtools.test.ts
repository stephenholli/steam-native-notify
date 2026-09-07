import { describe, expect, test } from 'bun:test';
import { isNumber, isToken, parseMepParam, planFire, toastFacts } from './lib/devtools';
import { formatJson, parseJson } from './lib/json';
import { decode, encode, frame, takeFrame } from './lib/msgpack';

describe('msgpack', () => {
	test('round-trips the request/response shapes MEP uses', () => {
		const v = {
			id: 'mep-cli',
			method: 'plugin.config.set',
			params: { name: 'me.tysmith.steam-native-notifications', key: 'devMode', value: true, n: 0, neg: -5, big: 70000, f: 1.5, none: null, list: [1, 'two', false] },
		};
		expect(decode(encode(v))).toEqual(v);
	});

	test('picks the smallest integer encodings and reads them back', () => {
		for (const n of [0, 1, 127, 128, 255, 256, 65535, 65536, 4294967295, 4294967296, -1, -32, -33, -128, -129, -32768, -32769, -2147483648, -2147483649]) {
			expect(decode(encode(n))).toBe(n);
		}
	});

	test('strings of every length class survive', () => {
		for (const n of [0, 31, 32, 255, 256, 70000]) {
			const s = 'é'.repeat(n);
			expect(decode(encode(s))).toBe(s);
		}
	});

	test('rejects a value that ends early', () => {
		const full = encode({ a: 'hello' });
		expect(() => decode(full.subarray(0, full.length - 1))).toThrow(/truncated/);
	});

	test('rejects bytes after the value', () => {
		const two = new Uint8Array([...encode('a'), ...encode('b')]);
		expect(() => decode(two)).toThrow(/trailing/);
	});

	test('rejects extension types rather than guessing', () => {
		expect(() => decode(new Uint8Array([0xd4, 0x01, 0x00]))).toThrow(/unsupported/);
	});

	test('frames carry a little-endian length and are taken whole', () => {
		const body = encode({ id: 'x' });
		const f = frame(body);
		expect(f[0]).toBe(body.length);
		expect(takeFrame(f.subarray(0, 3))).toBeNull();
		expect(takeFrame(f.subarray(0, f.length - 1))).toBeNull();
		const got = takeFrame(new Uint8Array([...f, 9, 9]));
		expect(got?.body).toEqual(body);
		expect(got?.rest).toEqual(new Uint8Array([9, 9]));
	});
});

describe('tools/fire argument grammar', () => {
	test('client toast: method name plus JSON args, parsed before the write', () => {
		const p = planFire(['TestFriendMessage', 'null', '"Ready to play?"']);
		expect(p).toEqual({ kind: 'queue', command: { call: 'TestFriendMessage', args: [null, 'Ready to play?'] }, message: expect.stringContaining('queued: TestFriendMessage [null,"Ready to play?"]') });
	});

	test('an unquoted string argument is refused before anything is written', () => {
		const p = planFire(['TestFriendMessage', 'null', 'Ready to play?']);
		expect(p.kind).toBe('error');
	});

	test('a method name is a token', () => {
		expect(planFire(['Test Download']).kind).toBe('error');
		expect(planFire(['NotificationStore.x']).kind).toBe('queue');
	});

	test('--wishlist defaults to Aircar and wants a numeric appid', () => {
		expect(planFire(['--wishlist'])).toMatchObject({ kind: 'queue', command: { server: { type: 8, body: { appid: 1073390, count: 1 } } } });
		expect(planFire(['--wishlist', '570'])).toMatchObject({ kind: 'queue', command: { server: { type: 8, body: { appid: 570, count: 1 } } } });
		expect(planFire(['--wishlist', 'abc']).kind).toBe('error');
	});

	test('--server wants a numeric type and a JSON body', () => {
		expect(planFire(['--server', '3', '{"appid":570}'])).toMatchObject({ kind: 'queue', command: { server: { type: 3, body: { appid: 570 } } } });
		expect(planFire(['--server', '3'])).toMatchObject({ kind: 'queue', command: { server: { type: 3, body: {} } } });
		expect(planFire(['--server', 'x']).kind).toBe('error');
		expect(planFire(['--server', '3', '{oops']).kind).toBe('error');
		expect(planFire(['--server']).kind).toBe('error');
	});

	test('--replay takes inspect or invoke and an optional toast name', () => {
		expect(planFire(['--replay', 'inspect'])).toMatchObject({ kind: 'queue', command: { replay: { call: 'inspect' } } });
		expect(planFire(['--replay', 'invoke', 'notificationtoasts_10004_desktop'])).toMatchObject({ kind: 'queue', command: { replay: { call: 'invoke', name: 'notificationtoasts_10004_desktop' } } });
		expect(planFire(['--replay']).kind).toBe('error');
		expect(planFire(['--replay', 'delete']).kind).toBe('error');
		expect(planFire(['--replay', 'invoke', 'a"b']).kind).toBe('error');
	});

	test('--overlay-info', () => {
		expect(planFire(['--overlay-info'])).toMatchObject({ kind: 'queue', command: { overlay: { call: 'info' } } });
	});

	test('subcommands are case-sensitive and a stray dash is refused', () => {
		expect(planFire(['--Replay', 'inspect']).kind).toBe('error');
		expect(planFire(['-x']).kind).toBe('error');
	});

	test('no arguments or --help is usage', () => {
		expect(planFire([]).kind).toBe('usage');
		expect(planFire(['--help']).kind).toBe('usage');
	});

	test('token and number predicates', () => {
		expect(isToken('notificationtoasts_10004_desktop')).toBe(true);
		expect(isToken('a b')).toBe(false);
		expect(isNumber('1073390')).toBe(true);
		expect(isNumber('8.5')).toBe(true);
		expect(isNumber('-1')).toBe(true);
		expect(isNumber('1e3')).toBe(true);
		expect(isNumber('abc')).toBe(false);
		expect(isNumber('01')).toBe(false);
	});
});

describe('tools/mep parameters', () => {
	test('values are JSON when they parse, else strings', () => {
		expect(parseMepParam('name=me.tysmith.steam-native-notifications')).toEqual(['name', 'me.tysmith.steam-native-notifications']);
		expect(parseMepParam('value=true')).toEqual(['value', true]);
		expect(parseMepParam('value=42')).toEqual(['value', 42]);
		expect(parseMepParam('value="go"')).toEqual(['value', 'go']);
		expect(parseMepParam('key=a=b')).toEqual(['key', 'a=b']);
		expect(() => parseMepParam('novalue')).toThrow(/key=value/);
	});

	test('integers beyond 2^53 keep every digit through a request and its reply', () => {
		// A steamid64 is 17 digits; JSON.parse alone would round it to ...680.
		const id = 76561198300097684n;
		expect(parseMepParam('value=76561198300097684')).toEqual(['value', id]);
		expect(parseMepParam('value=42')).toEqual(['value', 42]);
		expect(parseMepParam('value="76561198300097684"')).toEqual(['value', '76561198300097684']);
		expect(parseMepParam('body={"steamid":76561198300097684,"n":1}')).toEqual(['body', { steamid: id, n: 1 }]);
		expect(parseJson('-9007199254740993')).toBe(-9007199254740993n);
		expect(parseJson('9007199254740991')).toBe(9007199254740991);
		expect(parseJson('1.5')).toBe(1.5);

		const request = { id: 'mep-cli', method: 'plugin.config.set', params: { value: id } };
		const wire = encode(request);
		expect(Array.from(wire)).toContain(0xcf);
		expect(decode(wire)).toEqual(request);

		const printed = formatJson({ result: { steamid: id, small: 7 } });
		expect(printed).toContain('"steamid": 76561198300097684');
		expect(printed).toContain('"small": 7');
		expect(parseJson(printed)).toEqual({ result: { steamid: id, small: 7 } });
	});
});

describe('toast XML facts', () => {
	test('reads the shape notify-action.ps1 builds', () => {
		const xml =
			'<toast activationType="protocol" launch="steam://steam-native-notifications/notification/eyJ2IjoxfQ">' +
			'<visual><binding template="ToastGeneric"><text>Download Complete</text><text>Aircar &#8212; Your game &amp; DLC</text>' +
			'<image placement="appLogoOverride" hint-crop="circle" src="file:///C:/x/y.jpg"/></binding></visual></toast>';
		expect(toastFacts(xml)).toEqual({
			title: 'Download Complete',
			body: 'Aircar — Your game & DLC',
			imageSrc: 'file:///C:/x/y.jpg',
			imageCrop: 'circle',
			launch: 'steam://steam-native-notifications/notification/eyJ2IjoxfQ',
			activationType: 'protocol',
		});
	});

	test('a toast without an image or a second text', () => {
		const f = toastFacts('<toast><visual><binding template="ToastGeneric"><text>Only</text></binding></visual></toast>');
		expect(f).toMatchObject({ title: 'Only', body: null, imageSrc: '', imageCrop: '', launch: '', activationType: '' });
	});
});
