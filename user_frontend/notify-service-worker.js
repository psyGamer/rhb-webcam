self.addEventListener('push', event => {
    const data = event.data.json();
    const location = data.location;
    const file = data.file;

    // Parse timestamp
    const [date, time] = file.split('_');
    const [year, month, day] = date.split('-');
    const [hours, minutes, seconds] = time.split('-');
    const fileDate = new Date(year, month - 1, day, hours, minutes, seconds);

    const locationMames = {
        "filisur": "Filisur Webcam",
        "landwasser": "Landwasser Webcam",
        "landquart": "Landquart Webcam",
        "brusio": "Brusio Webcam",
        "livestream": "RhB Livestream"
    };

    event.waitUntil((async () => {
        const existing = await self.registration.getNotifications({ tag: location });
        const count = existing.length > 0 ? (existing[0].data.count ?? 1) + 1 : 1;

        await self.registration.showNotification(locationMames[location], {
            body: count == 1
                ? `Neue Aufnahme am ${dateStr}`
                : `${count} neue Aufnahmen seit dem ${count > 1 ? existing[0].data.dateStr : dateStr}`,
            tag: location,
            badge: "/rhb-72.png",
            icon: "/rhb-192.png",
            renotify: true,
            timestamp: fileDate.getTime(),
            data: { location, file, count, dateStr }
        })
    })())
});

self.addEventListener('notificationclick', function(event) {
    event.notification.close();
    event.waitUntil(
        clients.openWindow(`/${event.notification.data.location}/${event.notification.data.file}`)
    );
});

self.addEventListener('install', event => {
    self.skipWaiting();
});
self.addEventListener('activate', event => {
    event.waitUntil(clients.claim());
});