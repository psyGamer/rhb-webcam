const std = @import("std");
const tk = @import("tokamak");

const Env = @import("main.zig").Env;
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

    .post("/notify-test", notifyTest),
};

fn getPublicKey(env: *Env) []const u8 {
    return env.key(.VAPID_PUBLIC_KEY);
}

fn notifyTest(ctx: *tk.Context, env: *Env, body: struct { subscription: PushSubscription, location: Location }) !void {
    std.log.info("Loc: {}", .{body});

    sendNotification(ctx.allocator, env, body.subscription, "{\"title\":\"FloridaJS Notifications are amazing\",\"body\":\"And this event was well worth the money I spent on donations!\"}", .{}) catch |err| {
        std.log.err("Failed to send notif: {}", .{err});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
    };
    // sendNotification(ctx.allocator, env, .{ .endpoint = "https://updates.push.services.mozilla.com/wpush/v2/gAAAAABqFAtaG5VSXLuG4PL1hW7Vej8CFPtAL4h5HgsJ5tvFSBKGCWER7yskyagMAmAt4-uTCXbUWtIoh9bBZnzBlMk7KKg7GV6WqdRQJeiZxKKB6LXhqBnJgrs0vXDPBNo-UXoNAdqLa2-ozE2QfTijQC-vD6_jdNrmgjY21OHYKQCUbNrBZQM", .keys = .{
    //     .p256dh = "BOP9M8X29k3e8jT4Ro5cQ0Br-Au6KjlYYZIvzPAF0VF3BdN44ooqznLavmgHeeeinjodxRqGfZtdyJwppYjIGZY",
    //     .auth = "dOGxvxitQahrpG9wem8Pow",
    // } }, "{\"title\":\"FloridaJS Notifications are amazing\",\"body\":\"And this event was well worth the money I spent on donations!\"}", .{}) catch |err| {
    //     std.log.err("Failed to send notif: {}", .{err});
    //     if (@errorReturnTrace()) |trace| {
    //         std.debug.dumpStackTrace(trace.*);
    //     }
    // };
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
        std.log.warn("user_public: {b64}", .{user_public});
        const user_curve: Curve = try .fromSec1(&user_public);

        const user_auth = try allocator.alloc(u8, try Decoder.calcSizeForSlice(subscription.keys.auth));
        try Decoder.decode(user_auth, subscription.keys.auth);
        std.log.warn("user_auth: {b64}", .{user_auth});

        const local_kp: Scheme.KeyPair = .generate();
        // var local_private: [32]u8 = undefined;
        // try Decoder.decode(&local_private, "ImPlZrkY_G0iKV7YtEBI1a4QU6eHKkUHJQ1-ETLs4RA");
        // std.log.warn("local_private: {b64}", .{local_private});
        // const local_kp: Scheme.KeyPair = try .fromSecretKey(try .fromBytes(local_private));
        std.log.warn("local_public: {b64}", .{local_kp.public_key.toUncompressedSec1()});

        const shared_point = try user_curve.mul(local_kp.secret_key.toBytes(), .big);
        const local_secret = shared_point.affineCoordinates().x.toBytes(.big);
        std.log.warn("local_secret: {b64}", .{local_secret});

        const prk_combine = Hkdf.extract(user_auth, &local_secret);
        std.log.warn("prk_combine: {b64}", .{prk_combine});

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
        std.log.warn("ikm: {b64}", .{ikm});

        var salt: [16]u8 = undefined;
        std.crypto.random.bytes(&salt);
        // try Decoder.decode(&salt, "_NGbTDc023JZfXvJbQTHkA");
        std.log.warn("salt: {b64}", .{salt});

        const prk = Hkdf.extract(&salt, &ikm);
        std.log.warn("prk: {b64}", .{prk});

        const cek_info = "Content-Encoding: aes128gcm\x00";
        var cek: [Aes.key_length]u8 = undefined;
        Hkdf.expand(&cek, cek_info, prk);

        const nonce_info = "Content-Encoding: nonce\x00";
        var nonce: [Aes.nonce_length]u8 = undefined;
        Hkdf.expand(&nonce, nonce_info, prk);

        std.log.info("CEK {b64} NONCE {b64}", .{ cek, nonce });

        // var chipertext = try allocator.alloc(u8, payload.len + Aes.tag_length);
        // Aes.encrypt(chipertext[0..payload.len], chipertext[payload.len..][0..Aes.tag_length], payload, "", nonce, cek);

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
            std.log.info("block nonce {b64}", .{block_nonce});

            const plaintext = try allocator.alloc(u8, block.len + pad_length);
            defer allocator.free(plaintext);

            @memcpy(plaintext[0..block.len], block);
            plaintext[block.len] = if (last) 0x02 else 0x01; // Padding

            const out = try payload_buffer.addManyAsSlice(allocator, plaintext.len + Aes.tag_length);
            Aes.encrypt(out[0..plaintext.len], out[plaintext.len..][0..Aes.tag_length], plaintext, "", block_nonce, cek);

            std.log.info("encrypt: {b64}", .{block});
            std.log.info("encrypted: {b64}", .{out});

            start = end;
            counter += 1;

            if (last) break;
        }

        request_payload = payload_buffer.items;
        std.log.warn("result: {b64}", .{request_payload});

        headers.content_type = .{ .override = "application/octet-stream" };
        try extra_headers.append(allocator, .{ .name = "Content-Encoding", .value = "aes128gcm" });
    }

    // Sign message with JWT
    var server_private: [Scheme.SecretKey.encoded_length]u8 = undefined;
    std.debug.assert(server_private.len == try Decoder.calcSizeForSlice(env.key(.VAPID_PRIVATE_KEY)));
    try Decoder.decode(&server_private, env.key(.VAPID_PRIVATE_KEY));

    const server_kp: Scheme.KeyPair = try .fromSecretKey(try .fromBytes(server_private));

    const uri: std.Uri = try .parse(subscription.endpoint);

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
    , .{ uri.scheme, try (uri.host orelse return error.MissingEndpointHost).toRawMaybeAlloc(allocator), 1779786740, env.key(.VAPID_SUBJECT) });
    std.log.info("{s}", .{jwt_claims});

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

    var response_writer = std.Io.Writer.Allocating.init(allocator);

    const response = try client.fetch(.{
        .location = .{ .uri = uri },
        // .location = .{ .url = "http://localhost:8080" },
        .method = .POST,
        .response_writer = &response_writer.writer,

        .headers = headers,
        .extra_headers = extra_headers.items,
        .payload = request_payload,
    });

    if (response.status.class() != .success) {
        std.log.err("Failed to send notification to '{s}': {d} {s}", .{ subscription.endpoint, @intFromEnum(response.status), @tagName(response.status) });
        std.log.err("{s}", .{response_writer.written()});

        std.log.err("- Authorization: {s}", .{headers.authorization.override});
        for (extra_headers.items) |header| {
            std.log.err("- {s}: {s}", .{ header.name, header.value });
        }
        std.log.err("{any}", .{request_payload});

        return error.BadRequest;
    }
}
