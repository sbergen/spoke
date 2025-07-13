import {
    BitArray, Error, Ok
} from "../../gleam.mjs";

let WebSocketImpl;
if (typeof WebSocket !== 'undefined') {
    WebSocketImpl = WebSocket
} else {
    const ws = await import('ws')
    WebSocketImpl = ws.WebSocket || ws.default;
}

const Nil = undefined

export function connect(url, onOpen, onClose, onMessage, onError) {
    const socket = new WebSocketImpl(url, ["mqtt"]);

    socket.binaryType = "arraybuffer";
    socket.onopen = (_) => onOpen();
    socket.onclose = (_) => onClose();
    socket.onerror = (event) => onError(event.toString());
    socket.onmessage = (event) =>
        onMessage(new BitArray(new Uint8Array(event.data)));

    return socket;
}

export function close(socket) {
    socket.close();
}

export function send(socket, bitArray) {
    if (bitArray.bitSize / 8 !== bitArray.rawBuffer.length) {
        return new Error("BitArray to send contained partial bytes");
    }

    socket.send(bitArray.rawBuffer);
    return new Ok(Nil);
}
