const std = @import("std");

const Location = @import("common").Location;

pub const Source = enum {
    filisur_new,
    filisur_old,
    landwasser,
    landquart,
    brusio,
    alpgr,
    livestream,

    pub const attribution: std.EnumArray(Source, []const u8) = .init(.{
        .filisur_new =
        \\Quelle: © <a href="https://grischuna-filisur.ch">Hotel Grischuna</a>・<a href="https://grischuna-cam.weta.ch/cgi-bin/mjpg/video.cgi?channel=1&subtype=1">Live Video</a>
        ,
        .filisur_old =
        \\Quelle: © Manfred Luckmann via <a href="https://web.archive.org/web/20221206230559/https://schmalspurbahn.ch/">schmalspurbahn.ch</a>
        ,
        .landwasser =
        \\Quelle: © <a href="https://rhb.ch">Rhätische Bahn AG</a>・<a href="https://webcams.rhb.ch/Landwasserviadukt_c1.jpg">Live Bild (aktuell defekt)</a>
        ,
        .landquart =
        \\Quelle: © <a href="https://rhb.ch">Rhätische Bahn AG</a>・<a href="https://avisec.com/feed/S987773M7">Live Bild</a>
        ,
        .brusio =
        \\Quelle: © <a href="https://www.webcam.valtline.it/brusiog.htm">Valtline</a>・<a href="https://www.webcam.valtline.it/brusio.jpg">Live Bild</a>
        ,
        .alpgr =
        \\Quelle: © <a href="https://alpgruem.ch">Hotel Alp Grüm</a>・<a href="http://viewer:test@webcam2.internet-box.ch/channel2">Live Video</a>
        ,
        .livestream =
        \\Quelle: © <a href="https://rhb.ch">Rhätische Bahn AG</a>・<a href="https://www.rhb.ch/de/aktuelles/livestream">Livestream</a>
        ,
    });

    pub const location: std.EnumArray(Source, Location) = .init(.{
        .filisur_new = .filisur,
        .filisur_old = .filisur,
        .landwasser = .landwasser,
        .landquart = .landquart,
        .brusio = .brusio,
        .alpgr = .alpgr,
        .livestream = .livestream,
    });
};
