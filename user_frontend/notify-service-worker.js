self.addEventListener('push', event => {
    event.waitUntil(
        self.registration.showNotification('RhB Webcam', {
            body: 'Notification test',
        })
    );
});