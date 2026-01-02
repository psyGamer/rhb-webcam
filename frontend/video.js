class VideoPlayer {
    id = -1

    constructor(id) {
        this.id = id;
    }
}

class Video {
    /** @type {WebAssembly.Instance} */
    instance;
    
    constructor() {
        this.imports = {
            video_init: id => {
                console.info(`video_init`, id);
                const player = new VideoPlayer();
                return player;
            },
            video_deinit: player => {
                console.info(`video_deinit`, player);
                console.info(player.id);
            },
        }
    }

    setInstance(instance) {
        this.instance = instance;
    }
}