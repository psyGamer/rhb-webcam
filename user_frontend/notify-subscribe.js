console.log(webcam_location)

const subscribeBox = document.getElementById("notifications");

// Apply current state
subscribeBox.checked = localStorage.getItem(`notify-${webcam_location}`) == "true";

subscribeBox.addEventListener("change", async () => {
    localStorage.setItem(`notify-${webcam_location}`, subscribeBox.checked);

    navigator.serviceWorker.register("/notify-service-worker.js");

    const registration = await navigator.serviceWorker.ready;
    let subscription = await registration.pushManager.getSubscription();

    if (subscribeBox.checked) {
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
});

document.getElementById("notify-test").addEventListener("click", async () => {
    fetch("/notifications/notify-webcam", {
        method: "post",
        headers: {
            "Content-Type": "application/json"
        },
        body: JSON.stringify({
            password: "abc",
            location: webcam_location,
        }),
    });
})