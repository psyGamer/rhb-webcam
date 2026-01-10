class Meta {
    /** @type {WebAssembly.Instance} */
    instance;

    constructor() {
        this.imports = {
            window_get_path: () => {
                const path = utf8encoder.encode(window.location.pathname);
                const ptr = this.instance.exports.arena_u8(path.length + 1);

                var dest = new Uint8Array(this.instance.exports.memory.buffer, ptr, path.length + 1);
                dest.set(path);
                dest.set([0], path.length);

                return ptr;
            },
            window_get_search: () => {
                const search = utf8encoder.encode(window.location.search);
                const ptr = this.instance.exports.arena_u8(search.length + 1);

                var dest = new Uint8Array(this.instance.exports.memory.buffer, ptr, search.length + 1);
                dest.set(search);
                dest.set([0], search.length);

                return ptr;
            },
            window_set_url: (ptr, len) => {
                const path = utf8decoder.decode(
                    new Uint8Array(this.instance.exports.memory.buffer, ptr, len)
                );

                window.history.pushState({}, "", path);
            },

            get_timestamp: () => BigInt(Math.floor(Date.now() / 1000)),
        }
    }

    setInstance(instance) {
        this.instance = instance;
    }
}
