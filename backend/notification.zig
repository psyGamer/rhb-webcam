const std = @import("std");
const tk = @import("tokamak");
const fr = @import("fridge");

const database = @import("database.zig");

const Env = @import("main.zig").Env;
const Timestamp = @import("common").Timestamp;
const Location = @import("common").Location;

/// Web notification subscription
const PushSubscription = struct {
    endpoint: []const u8,
    keys: struct {
        auth: []const u8,
        p256dh: []const u8,
    },
};

pub const routes: []const tk.Route = &.{
    .get("/public-key", getPublicKey),

    .post("/register", register),
    .post("/unregister", unregister),

    .post("/send", sendWebcamNotifications),
};

fn getPublicKey(env: *Env) []const u8 {
    return env.key(.VAPID_PUBLIC_KEY);
}

fn register(db: *fr.Session, body: struct { subscription: PushSubscription, location: Location }) !void {
    try db.exec("BEGIN", .{});
    errdefer db.exec("ROLLBACK", .{}) catch {};

    try db.exec(
        std.fmt.comptimePrint(
            \\INSERT INTO {s} (endpoint, p256dh, auth) VALUES (?, ?, ?) ON CONFLICT (endpoint) DO NOTHING;
        , .{database.NotificationSubscription.sql_table_name}),
        .{ body.subscription.endpoint, body.subscription.keys.p256dh, body.subscription.keys.auth },
    );
    try db.exec(
        std.fmt.comptimePrint(
            \\INSERT INTO {s} (endpoint, webcam) VALUES (?, ?) ON CONFLICT (endpoint, webcam) DO NOTHING;
        , .{database.NotificationWebcam.sql_table_name}),
        .{ body.subscription.endpoint, @tagName(body.location) },
    );

    try db.exec("COMMIT", .{});
    std.log.info("Registered subscription to webcam '{s}' by '{s}'", .{ @tagName(body.location), body.subscription.endpoint });
}
fn unregister(db: *fr.Session, body: struct { subscription: PushSubscription, location: Location }) !void {
    try db.raw(
        std.fmt.comptimePrint(
            \\DELETE FROM {s} WHERE endpoint = ? AND webcam = ?
        , .{database.NotificationWebcam.sql_table_name}),
        .{ body.subscription.endpoint, @tagName(body.location) },
    ).exec();
    std.log.info("Unregistered subscription from webcam '{s}' by '{s}'", .{ @tagName(body.location), body.subscription.endpoint });
}

fn sendWebcamNotifications(arena: std.mem.Allocator, env: *Env, db: *fr.Session, body: struct { password: []const u8, location: Location, file: [Timestamp.time_fmt.len]u8 }) !void {
    // Validate password in constant time
    const password = env.key(.NOTIFICATION_PASSWORED);
    var invalid = false;
    for (body.password, 0..) |body_c, i| {
        const check_c = if (i < password.len) password[i] else 0;
        if (body_c != check_c) {
            invalid = true;
        }
    }

    if (invalid) {
        return error.Unauthorized;
    }

    var require_delete: std.ArrayList([]const u8) = .empty;

    {
        const raw = db.raw(std.fmt.comptimePrint(
            \\SELECT ns.endpoint, ns.p256dh, ns.auth
            \\FROM {s} ns
            \\JOIN {s} nw ON nw.endpoint = ns.endpoint
            \\WHERE nw.webcam = ?
        , .{ database.NotificationSubscription.sql_table_name, database.NotificationWebcam.sql_table_name }), .{@tagName(body.location)});

        var stmt = try raw.prepare();
        defer stmt.deinit();

        const payload = try std.fmt.allocPrint(arena,
            \\{{
            \\  "location": "{s}",
            \\  "file": "{s}"
            \\}}
        , .{ @tagName(body.location), body.file });

        while (try stmt.next(database.NotificationSubscription, db.arena)) |db_sub| {
            const sub: PushSubscription = .{
                .endpoint = db_sub.endpoint,
                .keys = .{
                    .p256dh = db_sub.p256dh,
                    .auth = db_sub.auth,
                },
            };
            sendNotification(arena, env, sub, payload, .{}) catch {
                // Clear erroring endpoints
                try require_delete.append(arena, try arena.dupe(u8, sub.endpoint));
            };
        }
    }

    for (require_delete.items) |item| {
        try db.raw(
            std.fmt.comptimePrint(
                \\DELETE FROM {s} WHERE endpoint = ?
            , .{database.NotificationSubscription.sql_table_name}),
            .{item},
        ).exec();
        std.log.info("Removed invalid endpoint '{s}'", .{item});
    }
}

const NotificationOptions = struct {
    urgency: enum { very_low, low, normal, high } = .normal,
};
fn sendNotification(allocator: std.mem.Allocator, env: *Env, subscription: PushSubscription, payload: []const u8, options: NotificationOptions) !void {
    var headers: std.http.Client.Request.Headers = .{};
    var extra_headers: std.ArrayList(std.http.Header) = .empty;

    try extra_headers.append(allocator, .{ .name = "TTL", .value = "86400" });

    const Scheme = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const Curve = std.crypto.ecc.P256;

    const Decoder = std.base64.url_safe_no_pad.Decoder;

    // Encrypt payload
    var request_payload: []const u8 = "";
    if (payload.len > 0) {
        const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
        const Aes = std.crypto.aead.aes_gcm.Aes128Gcm;

        const public_key_len = Scheme.PublicKey.uncompressed_sec1_encoded_length;

        // Create key and nonce for AES
        var user_public: [public_key_len]u8 = undefined;
        try Decoder.decode(&user_public, subscription.keys.p256dh);
        const user_curve: Curve = try .fromSec1(&user_public);

        const user_auth = try allocator.alloc(u8, try Decoder.calcSizeForSlice(subscription.keys.auth));
        try Decoder.decode(user_auth, subscription.keys.auth);

        const local_kp: Scheme.KeyPair = .generate();

        const shared_point = try user_curve.mul(local_kp.secret_key.toBytes(), .big);
        const local_secret = shared_point.affineCoordinates().x.toBytes(.big);

        const prk_combine = Hkdf.extract(user_auth, &local_secret);

        var ikm_info: ["WebPush: info\x00".len + public_key_len + public_key_len]u8 = undefined;
        comptime var ikm_offset = 0;
        ikm_info[ikm_offset..(ikm_offset + "WebPush: info\x00".len)].* = "WebPush: info\x00".*;
        ikm_offset += "WebPush: info\x00".len;
        @memcpy(ikm_info[ikm_offset..(ikm_offset + public_key_len)], &user_public);
        ikm_offset += public_key_len;
        @memcpy(ikm_info[ikm_offset..(ikm_offset + public_key_len)], &local_kp.public_key.toUncompressedSec1());
        ikm_offset += public_key_len;

        var ikm: [Hkdf.prk_length]u8 = undefined;
        Hkdf.expand(&ikm, &ikm_info, prk_combine);

        var salt: [16]u8 = undefined;
        std.crypto.random.bytes(&salt);

        const prk = Hkdf.extract(&salt, &ikm);

        const cek_info = "Content-Encoding: aes128gcm\x00";
        var cek: [Aes.key_length]u8 = undefined;
        Hkdf.expand(&cek, cek_info, prk);

        const nonce_info = "Content-Encoding: nonce\x00";
        var nonce: [Aes.nonce_length]u8 = undefined;
        Hkdf.expand(&nonce, nonce_info, prk);

        var payload_writer: std.io.Writer.Allocating = .init(allocator);
        var w = &payload_writer.writer;

        const record_size = 4096;

        // Write header
        try w.writeAll(&salt);
        try w.writeInt(u32, record_size, .big);
        try w.writeInt(u8, public_key_len, .big);
        try w.writeAll(&local_kp.public_key.toUncompressedSec1());
        try w.flush();

        var payload_buffer = payload_writer.toArrayList();

        // Perform AES encryption
        const pad_length = 1;
        const overhead = Aes.tag_length + pad_length;

        var start: usize = 0;
        var counter: u32 = 0;

        while (true) {
            const end = @min(start + record_size - overhead, payload.len);
            const last = end == payload.len;

            // Encrypt block
            const block = payload[start..end];

            const counter_bytes: []const u8 = @ptrCast(&std.mem.nativeToBig(u32, counter));
            var block_nonce: [Aes.nonce_length]u8 = nonce;
            block_nonce[8] ^= counter_bytes[0];
            block_nonce[9] ^= counter_bytes[1];
            block_nonce[10] ^= counter_bytes[2];
            block_nonce[11] ^= counter_bytes[3];

            const plaintext = try allocator.alloc(u8, block.len + pad_length);
            defer allocator.free(plaintext);

            @memcpy(plaintext[0..block.len], block);
            plaintext[block.len] = if (last) 0x02 else 0x01; // Padding

            const out = try payload_buffer.addManyAsSlice(allocator, plaintext.len + Aes.tag_length);
            Aes.encrypt(out[0..plaintext.len], out[plaintext.len..][0..Aes.tag_length], plaintext, "", block_nonce, cek);

            start = end;
            counter += 1;

            if (last) break;
        }

        request_payload = payload_buffer.items;

        headers.content_type = .{ .override = "application/octet-stream" };
        try extra_headers.append(allocator, .{ .name = "Content-Encoding", .value = "aes128gcm" });
    }

    // Sign message with JWT
    var server_private: [Scheme.SecretKey.encoded_length]u8 = undefined;
    std.debug.assert(server_private.len == try Decoder.calcSizeForSlice(env.key(.VAPID_PRIVATE_KEY)));
    try Decoder.decode(&server_private, env.key(.VAPID_PRIVATE_KEY));

    const server_kp: Scheme.KeyPair = try .fromSecretKey(try .fromBytes(server_private));

    const uri: std.Uri = try .parse(subscription.endpoint);

    // Valid for a day
    const now = std.time.timestamp();
    const exp = now + std.time.s_per_day;

    const jwt_header =
        \\{
        \\  "typ": "JWT",
        \\  "alg": "ES256"
        \\}
    ;
    const jwt_claims = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "aud": "{s}://{s}",
        \\  "exp": {d},
        \\  "sub": "{s}"
        \\}}
    , .{ uri.scheme, try (uri.host orelse return error.MissingEndpointHost).toRawMaybeAlloc(allocator), exp, env.key(.VAPID_SUBJECT) });

    const Encoder = std.base64.url_safe_no_pad.Encoder;

    var encoded_header_buffer: [Encoder.calcSize(jwt_header.len)]u8 = undefined;
    const encoded_header = Encoder.encode(&encoded_header_buffer, jwt_header);

    const encoded_claims_buffer = try allocator.alloc(u8, Encoder.calcSize(jwt_claims.len));
    const encoded_claims = Encoder.encode(encoded_claims_buffer, jwt_claims);

    const encoded_payload = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ encoded_header, encoded_claims });

    const jwt_signature = (try server_kp.sign(encoded_payload, null)).toBytes();

    var encoded_signature_buffer: [Encoder.calcSize(jwt_signature.len)]u8 = undefined;
    const encoded_signature = Encoder.encode(&encoded_signature_buffer, &jwt_signature);

    const jwt = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ encoded_payload, encoded_signature });

    // Setup VAPID headers
    headers.authorization = .{ .override = try std.fmt.allocPrint(allocator, "vapid t={s}, k={s}", .{ jwt, env.key(.VAPID_PUBLIC_KEY) }) };

    // Setup notification headers
    try extra_headers.append(allocator, .{ .name = "Urgency", .value = switch (options.urgency) {
        .very_low => "very-low",
        .low => "low",
        .normal => "normal",
        .high => "high",
    } });

    // Send request
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const response = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .POST,

        .headers = headers,
        .extra_headers = extra_headers.items,
        .payload = request_payload,
    });

    if (response.status.class() != .success) {
        std.log.err("Notification server '{s}' returned {d} {s}", .{ subscription.endpoint, @intFromEnum(response.status), @tagName(response.status) });
        return error.BadRequest;
    }
}
