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

    sendNotification(ctx.allocator, env, body.subscription, "", .{}) catch |err| {
        std.log.err("Failed to send notif: {}", .{err});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
    };
}

const NotificationOptions = struct {
    content_encoding: enum { aes_128_gcm, aes_gcm } = .aes_128_gcm,
    urgency: enum { very_low, low, normal, high } = .normal,
};
fn sendNotification(allocator: std.mem.Allocator, env: *Env, subscription: PushSubscription, payload: []const u8, options: NotificationOptions) !void {
    _ = payload;

    var headers: std.http.Client.Request.Headers = .{};
    var extra_headers: std.ArrayList(std.http.Header) = .empty;

    try extra_headers.append(allocator, .{ .name = "TTL", .value = "60" });

    const Scheme = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const Decoder = std.base64.standard_no_pad.Decoder;

    // Encrypt payload
    // var request_payload = "";
    // if (payload.len > 0) {
    //     const local_kp: Scheme.KeyPair = .generate();
    //     var salt: [16]u8 = undefined;
    //     std.crypto.random.bytes(&salt);

    //     const AesGcm = std.crypto.aead.aes_gcm.Aes128Gcm;
    // }

    // Sign message with JWT

    var pk: [Scheme.SecretKey.encoded_length]u8 = undefined;
    std.debug.assert(pk.len == try Decoder.calcSizeForSlice(env.key(.VAPID_PRIVATE_KEY)));
    try Decoder.decode(&pk, env.key(.VAPID_PRIVATE_KEY));

    const kp: Scheme.KeyPair = try .fromSecretKey(try .fromBytes(pk));

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

    const jwt_signature = (try kp.sign(encoded_payload, null)).toBytes();

    var encoded_signature_buffer: [Encoder.calcSize(jwt_signature.len)]u8 = undefined;
    const encoded_signature = Encoder.encode(&encoded_signature_buffer, &jwt_signature);

    const jwt = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ encoded_payload, encoded_signature });

    // Setup VAPID headers
    switch (options.content_encoding) {
        .aes_128_gcm => {
            headers.authorization = .{ .override = try std.fmt.allocPrint(allocator, "vapid t={s}, k={s}", .{ jwt, env.key(.VAPID_PUBLIC_KEY) }) };
        },
        .aes_gcm => {
            headers.authorization = .{ .override = try std.fmt.allocPrint(allocator, "WebPush {s}", .{jwt}) };
            try extra_headers.append(allocator, .{ .name = "Crypto-Key", .value = try std.fmt.allocPrint(allocator, "p256ecdsa={s}", .{env.key(.VAPID_PUBLIC_KEY)}) });
        },
    }

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
        .method = .POST,
        .response_writer = &response_writer.writer,

        .headers = headers,
        .extra_headers = extra_headers.items,
        .payload = "",
    });

    if (response.status.class() != .success) {
        std.log.err("Failed to send notification to '{s}': {d} {s}", .{ subscription.endpoint, @intFromEnum(response.status), @tagName(response.status) });
        std.log.err("{s}", .{response_writer.written()});

        std.log.err("- Authorization: {s}", .{headers.authorization.override});
        for (extra_headers.items) |header| {
            std.log.err("- {s}: {s}", .{ header.name, header.value });
        }

        return error.BadRequest;
    }
}
