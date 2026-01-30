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
                const path = utf8decoder.decode(new Uint8Array(this.instance.exports.memory.buffer, ptr, len));

                window.history.pushState({}, "", path);
            },

            get_timestamp: () => BigInt(Math.floor(Date.now() / 1000)),

            url_fetch: (method, url_ptr, url_len, body_ptr, body_len, userdata) => {
                const url  = utf8decoder.decode(new Uint8Array(this.instance.exports.memory.buffer, url_ptr, url_len));
                const body = body_ptr ? utf8decoder.decode(new Uint8Array(this.instance.exports.memory.buffer, body_ptr, body_len)) : null;

                let method_str;
                switch (method) {
                    case 0:
                        method_str = "GET";
                        break;
                    case 1:
                        method_str = "HEAD";
                        break;
                    case 2:
                        method_str = "POST";
                        break;
                    case 3:
                        method_str = "PUT";
                        break;
                    case 4:
                        method_str = "DELETE";
                        break;
                    case 5:
                        method_str = "CONNECT";
                        break;
                    case 6:
                        method_str = "OPTIONS";
                        break;
                    case 7:
                        method_str = "TRACE";
                        break;
                    case 8:
                        method_str = "PATCH";
                        break;
                }
                
                fetch(url, {
                    method: method_str,
                    body: body,
                }).then(async (response) => {
                    const blob = await response.blob();
                    const bytes = new Uint8Array(await blob.arrayBuffer());

                    const ptr = this.instance.exports.arena_u8(bytes.length);

                    var dest = new Uint8Array(this.instance.exports.memory.buffer, ptr, bytes.length);
                    dest.set(bytes);

                    this.instance.exports.url_callback(userdata, response.status, ptr, bytes.length);
                });
            },
        }
    }

    setInstance(instance) {
        this.instance = instance;
    }
}
