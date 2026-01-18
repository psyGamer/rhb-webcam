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

    /** @type {string} */
    src;
    /** @type {boolean} */
    loading;
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

    constructor(instance, dvui, src) {
        this.instance = instance;

        this.src = src;
        this.loading = true;
        this.video = document.createElement('video');
        this.video.src = src;
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

            this.loading = false;
            dvui.requestRender();
        })
        document.body.appendChild(this.video);
    }

    deinit(dvui) {
        dvui.textures.delete(this.textureId);
        dvui.gl.deleteTexture(this.texture);

        this.video.remove();
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
class ImageViewer {
    /** @type {WebAssembly.Instance} */
    instance;

    /** @type {WebGLTexture} */
    texture;
    /** @type {number} */
    textureId;

    /** Tracks if the viewer was used this frame, for automatic cleanup */
    used = true;

    /** @type {string} */
    src;
    /** @type {boolean} */
    loading;
    /** @type {HTMLImageElement} */
    image;

    constructor(instance, dvui, src) {
        this.instance = instance;

        this.src = src;
        this.loading = true;
        this.image = document.createElement('img');
        this.image.src = src;
        this.image.style.display = 'none';
        this.image.addEventListener("load", async () => {
            // Allocate texture
            this.textureId = dvui.newTextureId;
            dvui.newTextureId += 1;

            this.texture = dvui.gl.createTexture();
            dvui.textures.set(this.textureId, [this.texture, this.image.naturalWidth, this.image.naturalHeight]);

            dvui.gl.bindTexture(dvui.gl.TEXTURE_2D, this.texture);

            // Upload data
            dvui.gl.texImage2D(
                dvui.gl.TEXTURE_2D,
                0,
                dvui.gl.RGBA,
                this.image.naturalWidth,
                this.image.naturalHeight,
                0,
                dvui.gl.RGBA,
                dvui.gl.UNSIGNED_BYTE,
                this.image,
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

            this.loading = false;
            dvui.requestRender();
        })
        document.body.appendChild(this.image)
    }

    deinit(dvui) {
        dvui.textures.delete(this.textureId);
        dvui.gl.deleteTexture(this.texture);

        this.video.remove();
    }
}

class Video {
    /** @type {Dvui} */
    dvui;
    /** @type {WebAssembly.Instance} */
    instance;

    /** @type {Map<Id, VideoPlayer>} */
    activePlayers = new Map();
    /** @type {Map<Id, ImageViewer>} */
    activeViewers = new Map();
    
    constructor(dvui) {
        this.dvui = dvui;
        this.imports = {
            video_init: (id, ptr, len) => {
                const src = utf8decoder.decode(new Uint8Array(this.instance.exports.memory.buffer, ptr, len));

                let player = this.activePlayers.get(id);
                if (player) {
                    player.used = true;
                    if (player.src != src) {
                        player.src = src;
                        player.loading = true;
                        player.video.src = src;
                    }
                    player.draw(this.dvui);
                    return player.loading ? 0 : player.textureId;
                }

                player = new VideoPlayer(this.instance, this.dvui, src);
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
            video_play: id => {
                const player = this.activePlayers.get(id);
                if (player) {
                    player.video.play();
                }
            },
            video_pause: id => {
                const player = this.activePlayers.get(id);
                if (player) {
                    player.video.pause();
                }
            },
            video_is_paused: id => {
                const player = this.activePlayers.get(id);
                if (player) {
                    return player.video.paused;
                }

                return false;
            },
            video_set_position: (id, time) => {
                const player = this.activePlayers.get(id);
                if (player) {
                    player.video.currentTime = time;
                }
            },
            video_get_position: id => {
                const player = this.activePlayers.get(id);
                if (player) {
                    return player.video.currentTime;
                }

                return 0;
            },
            video_get_duration: id => {
                const player = this.activePlayers.get(id);
                if (player) {
                    return player.video.duration;
                }

                return 0;
            },
            video_set_speed: (id, speed) => {
                const player = this.activePlayers.get(id);
                if (player) {
                    player.video.playbackRate = speed;
                }
            },
            video_get_speed: id => {
                const player = this.activePlayers.get(id);
                if (player) {
                    return player.video.playbackRate;
                }

                return 1;
            },
            video_cleanup_unused: () => {
                this.activePlayers.entries().forEach(kv => {
                    const [id, player] = kv;

                    // Remove unused
                    if (!player.used) {
                        player.deinit(this.dvui);
                        this.activePlayers.delete(id);
                    }
                    // Reset flag
                    player.used = false;
                })
            },

            image_init: (id, ptr, len) => {
                const src = utf8decoder.decode(new Uint8Array(this.instance.exports.memory.buffer, ptr, len));

                let viewer = this.activeViewers.get(id);
                if (viewer) {
                    viewer.used = true;
                    if (viewer.src != src) {
                        viewer.src = src;
                        viewer.loading = true;
                        viewer.image.src = src;
                    }
                    return viewer.loading ? 0 : viewer.textureId;
                }

                viewer = new ImageViewer(this.instance, this.dvui, src);
                this.activeViewers.set(id, viewer);

                return viewer.textureId;
            },
            image_width: id => {
                const viewer = this.activeViewers.get(id);
                if (viewer) {
                    return this.dvui.textures.get(viewer.textureId)[1];
                }

                return 0;
            },
            image_height: id => {
                const viewer = this.activeViewers.get(id);
                if (viewer) {
                    return this.dvui.textures.get(viewer.textureId)[2];
                }

                return 0;
            },
            image_cleanup_unused: () => {
                this.activeViewers.entries().forEach(kv => {
                    const [id, viewer] = kv;

                    // Remove unused
                    if (!viewer.used) {
                        viewer.deinit(this.dvui);
                        this.activeViewers.delete(id);
                    }
                    // Reset flag
                    viewer.used = false;
                })
            },

        }
    }

    setInstance(instance) {
        this.instance = instance;
    }
}
