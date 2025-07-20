import {
    BitArray, Error, Ok
} from "../../gleam.mjs";

const Nil = undefined

export function connect(url, onOpen, onClose, onMessage, onError) {
    const socket = new WebSocket(url, ["mqtt"]);

    let isOpen = false;
    socket.binaryType = "arraybuffer";

    socket.onopen = (_) => {
        isOpen = true;
        onOpen();
    }

    socket.onclose = (_) => {
        isOpen = false;
        onClose();
    }

    socket.onerror = (event) => {
        // Cross-platform errors seem to be complicated.
        // Maybe I'll look into it one day...
        onError(isOpen ? "Connection failed" : "Failed to connect");
    }

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
