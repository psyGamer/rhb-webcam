const std = @import("std");

const Timestamp = @import("common").Timestamp;
const Clock = @import("common").Schedule.Clock;
const Locomotive = @import("common").Locomotive;
const Source = @import("source.zig").Source;
const Location = @import("common").Location;

pub const Options = struct {
    pub const Train = struct {
        number: u32,

        classifier: []const u8,
        origin: []const u8,
        destination: []const u8,

        time: union(enum) {
            shunting: void,
            arrival: Clock,
            departure: Clock,
            transit: Clock,
            stop: struct { Clock, Clock },
        },

        locomotives: []const Locomotive,
    };

    title: []const u8,
    source: Source,

    time: Timestamp,
    path: [Timestamp.time_fmt.len]u8,

    next: ?[Timestamp.time_fmt.len]u8,
    prev: ?[Timestamp.time_fmt.len]u8,

    trains: []const Train = &.{},

    has_video: bool,
};

pub fn render(writer: *std.Io.Writer, opts: Options) !void {
    const location: Location = switch (opts.source) {
        .filisur_old, .filisur_new => .filisur,
        .landwasser => .landwasser,
        .landquart => .landquart,
        .brusio => .brusio,
        .alpgr => .alpgr,
        .livestream => .livestream,
    };

    try writer.print(
        \\    <div class="main">
        \\        <div class="title">
        \\            <h3 class="heading">{s}</h3>
        \\            <p class="subtext">{d}. {s} {d} um {d:0>2}:{d:0>2}:{d:0>2}</p>
        \\
        \\            <div class="capture-navigation">
        \\                <a class="icon-button {s}" href="/{s}/{s}">
        \\                    <!-- Source: https://icongr.am/entypo/chevron-left.svg -->
        \\                    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 20 20" fill="currentColor">
        \\                        <g>
        \\                            <path d="M12.452 4.516c.446.436.481 1.043 0 1.576L8.705 10l3.747 3.908c.481.533.446 1.141 0 1.574-.445.436-1.197.408-1.615 0-.418-.406-4.502-4.695-4.502-4.695a1.095 1.095 0 0 1 0-1.576s4.084-4.287 4.502-4.695c.418-.409 1.17-.436 1.615 0z"/>
        \\                        </g>
        \\                    </svg>
        \\                </a>
        \\                <a class="text-button" href="/{s}/archive/{d}-{d:0>2}-{d:0>2}">Übersicht <b>{d}. {s} {d}</b></a>
        \\                <a class="icon-button {s}" href="/{s}/{s}">
        \\                    <!-- Source: https://icongr.am/entypo/chevron-right.svg -->
        \\                    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 20 20" fill="currentColor">
        \\                        <g>
        \\                            <path d="M9.163 4.516c.418.408 4.502 4.695 4.502 4.695a1.095 1.095 0 0 1 0 1.576s-4.084 4.289-4.502 4.695c-.418.408-1.17.436-1.615 0-.446-.434-.481-1.041 0-1.574L11.295 10 7.548 6.092c-.481-.533-.446-1.141 0-1.576.445-.436 1.197-.409 1.615 0z"/>
        \\                        </g>
        \\                    </svg>
        \\                </a>
        \\            </div>
        \\        </div>
        \\    
        \\        <div class="view">
        \\            <div class="media">
        \\                <div class="content">
        \\                    <img src="/{s}/image/{s}" alt="{s} Webcam Bild">
        \\
    , .{
        opts.title,

        opts.time.day,
        opts.time.monthName(),
        opts.time.year,
        opts.time.hour,
        opts.time.minute,
        opts.time.second,

        if (opts.prev == null) "disabled" else "",
        @tagName(location),
        if (opts.prev) |prev| &prev else "",

        @tagName(location),
        opts.time.year,
        opts.time.month,
        opts.time.day,
        opts.time.day,
        opts.time.monthName(),
        opts.time.year,

        if (opts.next == null) "disabled" else "",
        @tagName(location),
        if (opts.next) |next| &next else "",

        @tagName(location),
        opts.path,

        Location.names.get(location),
    });

    if (opts.has_video) {
        try writer.print(
            \\                    <video src="/{s}/video/{s}" alt="{s} Webcam Video" controls muted></video>
            \\                </div>
            \\
            \\                <div class="meta">
            \\                    <button class="toggle-display" aria-pressed="false" title="Toggle between image and video" onclick="toggleImageVideo(this)">
            \\                        <span class="toggle-option toggle-image">
            \\                            <!-- Source: https://icongr.am/entypo/image.svg -->
            \\                            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 20 20" width="32" height="32">
            \\                                <g>
            \\                                    <path fill-rule="evenodd" clip-rule="evenodd" d="M19 2H1a1 1 0 0 0-1 1v14a1 1 0 0 0 1 1h18a1 1 0 0 0 1-1V3a1 1 0 0 0-1-1zm-1 14H2V4h16v12zm-3.685-5.123l-3.231 1.605-3.77-6.101L4 14h12l-1.685-3.123zM13.25 9a1.25 1.25 0 1 0 0-2.5 1.25 1.25 0 0 0 0 2.5z"/>
            \\                                </g>
            \\                            </svg>
            \\                            Bild
            \\                        </span>
            \\                        <span class="toggle-slider"></span>
            \\                        <span class="toggle-option toggle-video">
            \\                            <!-- Source: https://icongr.am/entypo/video.svg -->
            \\                            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 20 20" width="32" height="32">
            \\                                <g>
            \\                                    <path d="M20 5V3.799A.798.798 0 0 0 19.201 3H.801A.8.8 0 0 0 0 3.799V5h2v2H0v2h2v2H0v2h2v2H0v1.199A.8.8 0 0 0 .801 17h18.4a.8.8 0 0 0 .799-.801V15h-2v-2h2v-2h-2V9h2V7h-2V5h2zM8 13V7l5 3-5 3z"/>
            \\                                </g>
            \\                            </svg>
            \\                            Video
            \\                        </span>
            \\                    </button>
            \\
            \\                    <div class="info">{s}</div>
            \\                </div>
            \\            </div>
            \\
            \\            <div class="trains" aria-label="Liste der Züge">
            \\
        , .{ @tagName(location), opts.path, Location.names.get(location), Source.attribution.get(opts.source) });
    } else {
        try writer.print(
            \\                </div>
            \\
            \\                <div class="meta">
            \\                    <div class="info">{s}</div>
            \\                </div>
            \\            </div>
            \\
            \\            <div class="trains" aria-label="Liste der Züge">
            \\
        , .{Source.attribution.get(opts.source)});
    }

    for (opts.trains) |train| {
        if (train.number == 0) {
            try writer.print(
                \\                <div class="train-item">
                \\                    <div class="header">
                \\                        <div class="info">
                \\                            <b>{s}</b>
                \\                        </div>
                \\
            , .{train.classifier});
        } else {
            try writer.print(
                \\                <div class="train-item">
                \\                    <div class="header">
                \\                        <div class="info">
                \\                            <span class="train-number">{d}</span>
                \\                            <b>{s}</b>
                \\                        </div>
                \\
            , .{ train.number, train.classifier });
        }

        if (train.origin.len > 0 and train.destination.len > 0) {
            try writer.print(
                \\                        <span class="direction">
                \\                            {s}
                \\                            <!-- Source: https://icongr.am/entypo/arrow-long-right.svg -->
                \\                            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 20 20" width="32" height="32" fill="currentColor">
                \\                                <g>
                \\                                    <path d="M14 15.5V12H1V8h13V4.5l5.25 5.5L14 15.5z"/>
                \\                                </g>
                \\                            </svg>
                \\                            {s}
                \\                        </span>
                \\
            , .{ train.origin, train.destination });
        }

        switch (train.time) {
            .shunting => {}, // Show nothing
            .arrival => |time| try writer.print(
                \\                        <span class="badge arrival">Ankunft {f}</span>
            , .{time}),
            .departure => |time| try writer.print(
                \\                        <span class="badge departure">Abfahrt {f}</span>
            , .{time}),
            .transit => |time| try writer.print(
                \\                        <span class="badge transit">Durchfahrt {f}</span>
            , .{time}),
            .stop => |time| try writer.print(
                \\                        <span class="badge transit">Halt {f}-{f}</span>
            , .{ time[0], time[1] }),
        }

        try writer.writeAll(
            \\
            \\                    </div>
            \\                    <ul>
            \\
        );

        for (train.locomotives) |loco| {
            try writer.print(
                \\                        <li>
                \\                            {s}
                \\                            <b>{d} «{s}»</b>
                \\
            , .{
                Locomotive.category_names.get(loco.category),
                loco.number,
                Locomotive.getVariantName(loco.number, .{ .day = opts.time.day, .month = @intFromEnum(opts.time.month), .year = opts.time.year }),
            });

            if (loco.towed) {
                try writer.writeAll(
                    \\                            <span class="badge towed">Geschleppt</span>
                );
            }
            try writer.writeAll(
                \\                        </li>
                \\
            );
        }

        try writer.writeAll(
            \\                    </ul>
            \\                </div>
            \\
        );
    }

    try writer.writeAll(
        \\            </div>
        \\        </div>
        \\        
        \\    </div>
        \\
        \\    <script>
        \\        const image = document.querySelector('.content img');
        \\        const video = document.querySelector('.content video');
        \\        const trainList = document.querySelector('.trains');
        \\
        \\        function toggleImageVideo(button) {
        \\            if (button.getAttribute('aria-pressed') === 'false') {
        \\                image.style.display = 'none';
        \\                video.style.display = 'block';
        \\                video.play();
        \\                button.setAttribute('aria-pressed', true);
        \\            } else {
        \\                video.style.display = 'none';
        \\                image.style.display = 'block';
        \\                button.setAttribute('aria-pressed', false);
        \\            }
        \\        }
        \\
        \\        // Match train list height to image/video height
        \\        function setTrainsMaxHeight(){
        \\            const rect = image.getBoundingClientRect();
        \\            if(rect && rect.height > 0){
        \\                trainList.style.maxHeight = Math.round(rect.height) + 'px';
        \\            }
        \\        }
        \\
        \\        if(image.complete && image.naturalHeight !== 0){
        \\            setTrainsMaxHeight();
        \\        } else {
        \\            image.addEventListener('load', setTrainsMaxHeight);
        \\        }
        \\
        \\        window.addEventListener('resize', () => setTrainsMaxHeight())
        \\    </script>
        \\
    );
}
