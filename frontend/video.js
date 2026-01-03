/**@typedef {BigInt} Id */

class VideoPlayer {
    /** @type {WebAssembly.Instance} */
    instance;

    /** @type {WebGLTexture} */
    texture;
    /** @type {number} */
    textureId;

    /** Tracks if the player was used this frame, for automatic cleanup */
    used = true;

    /** @type {HTMLVideoElement} */
    video;
    /** @type {MediaStream} */
    stream;
    /** @type {MediaStreamTrack} */
    track;

    /** @type {MediaStreamTrackProcessor} */
    processor;
    /** @type {ReadableStream} */
    reader;

    constructor(instance, dvui) {
        this.instance = instance;

        this.video = document.createElement('video');
        this.video.src = "/example.mp4";
        this.video.muted = true;
        this.video.playsInline = true;
        this.video.style.display = 'none';
        this.video.play();
        this.video.addEventListener("loadeddata", async () => {
            // Allocate texture
            this.textureId = dvui.newTextureId;
            dvui.newTextureId += 1;

            this.texture = dvui.gl.createTexture();
            dvui.textures.set(this.textureId, [this.texture, this.video.videoWidth, this.video.videoHeight]);
            console.log(this.video.videoWidth, this.video.videoHeight)

            dvui.gl.bindTexture(dvui.gl.TEXTURE_2D, this.texture);

            // Upload data
            dvui.gl.texImage2D(
                dvui.gl.TEXTURE_2D,
                0,
                dvui.gl.RGBA,
                this.video.videoWidth,
                this.video.videoHeight,
                0,
                dvui.gl.RGBA,
                dvui.gl.UNSIGNED_BYTE,
                this.video,
            );
            
            dvui.gl.texParameteri(
                dvui.gl.TEXTURE_2D,
                dvui.gl.TEXTURE_MIN_FILTER,
                dvui.gl.LINEAR,
            );
            dvui.gl.texParameteri(
                dvui.gl.TEXTURE_2D,
                dvui.gl.TEXTURE_MAG_FILTER,
                dvui.gl.LINEAR,
            );

            dvui.gl.texParameteri(
                dvui.gl.TEXTURE_2D,
                dvui.gl.TEXTURE_WRAP_S,
                dvui.gl.CLAMP_TO_EDGE,
            );
            dvui.gl.texParameteri(
                dvui.gl.TEXTURE_2D,
                dvui.gl.TEXTURE_WRAP_T,
                dvui.gl.CLAMP_TO_EDGE,
            );

            dvui.gl.bindTexture(dvui.gl.TEXTURE_2D, null);

            dvui.requestRender();
        })
        document.body.appendChild(this.video)
    }

    deinit(dvui) {
        dvui.textures.delete(this.textureId);
        dvui.gl.deleteTexture(this.texture);

        this.video.remove();
    }

    play() {
        this.video.play();
    }

    draw(dvui) {
        if (this.video.readyState >= this.video.HAVE_CURRENT_DATA) {
            dvui.gl.bindTexture(dvui.gl.TEXTURE_2D, this.texture);

            dvui.gl.texImage2D(
                dvui.gl.TEXTURE_2D,
                0,
                dvui.gl.RGBA,
                this.video.videoWidth,
                this.video.videoHeight,
                0,
                dvui.gl.RGBA,
                dvui.gl.UNSIGNED_BYTE,
                this.video,
            );

            dvui.gl.bindTexture(dvui.gl.TEXTURE_2D, null);
        }

        if (!this.video.paused) {
            // Keep rendering video
            dvui.requestRender();
        }
    }
}

class Video {
    /** @type {Dvui} */
    dvui;
    /** @type {WebAssembly.Instance} */
    instance;

    /** @type {Map<Id, VideoPlayer>} */
    activePlayers = new Map();
    
    constructor(dvui) {
        this.dvui = dvui;
        this.imports = {
            video_init: id => {
                let player = this.activePlayers.get(id);
                if (player) {
                    player.used = true;
                    player.draw(this.dvui);
                    return player.textureId;
                }

                console.info(`video_init`, id);
                player = new VideoPlayer(this.instance, this.dvui);
                this.activePlayers.set(id, player);

                return player.textureId;
            },
            video_width: id => {
                const player = this.activePlayers.get(id);
                if (player) {
                    return this.dvui.textures.get(player.textureId)[1];
                }

                return 0;
            },
            video_height: id => {
                const player = this.activePlayers.get(id);
                if (player) {
                    return this.dvui.textures.get(player.textureId)[2];
                }

                return 0;
            },
            video_pause: id => {
                const player = this.activePlayers.get(id);
                if (player) {
                    player.pause();
                }
            },
            video_cleanup_unused: () => {
                this.activePlayers.entries().forEach(kv => {
                    const [id, player] = kv;

                    // Remove unused
                    if (!player.used) {
                        console.info(`video_deinit`, id);
                        player.deinit(this.dvui);
                        this.activePlayers.delete(id);
                    }
                    // Reset flag
                    player.used = false;
                })
            },
        }
    }

    setInstance(instance) {
        this.instance = instance;
    }
}