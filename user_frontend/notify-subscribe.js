console.log(webcam_location)

const notificationsCheckbox = document.getElementById("notifications");
const notificationsSideCheckbox = document.getElementById("notifications-side");

// Apply current state
notificationsCheckbox.checked = notificationsSideCheckbox.checked = localStorage.getItem(`notify-${webcam_location}`) == "true";

notificationsCheckbox.addEventListener("change", async () => {
    localStorage.setItem(`notify-${webcam_location}`, notificationsCheckbox.checked);
    notificationsSideCheckbox.checked = notificationsCheckbox.checked;

    await handleChanged(notificationsCheckbox.checked);
});
notificationsSideCheckbox.addEventListener("change", async () => {
    localStorage.setItem(`notify-${webcam_location}`, notificationsSideCheckbox.checked);
    notificationsCheckbox.checked = notificationsSideCheckbox.checked;

    await handleChanged(notificationsSideCheckbox.checked);
});

async function handleChanged(state) {
    navigator.serviceWorker.register("/notify-service-worker.js");

    const registration = await navigator.serviceWorker.ready;
    let subscription = await registration.pushManager.getSubscription();

    if (state) {
        // Subscribe to webcam
        if (!subscription) {
            // Create subscription
            const response = await fetch("/notifications/public-key");
            const vapidPublicKey = await response.text();

            subscription = await registration.pushManager.subscribe({
                userVisibleOnly: true,
                applicationServerKey: vapidPublicKey,
            });
        }

        // Send subscription to server
        fetch("/notifications/register", {
            method: "post",
            headers: {
                "Content-Type": "application/json"
            },
            body: JSON.stringify({
                subscription: subscription,
                location: webcam_location,
            }),
        });
    } else if (subscription) {
        // Unsubscribe from webcam
        fetch("/notifications/unregister", {
            method: "post",
            headers: {
                "Content-Type": "application/json"
            },
            body: JSON.stringify({
                subscription: subscription,
                location: webcam_location,
            }),
        });
    }
}
