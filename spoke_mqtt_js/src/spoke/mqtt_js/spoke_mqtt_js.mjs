import {
    BitArray,
} from "../../gleam.mjs";
import WebSocket from 'ws';

export function connect(url, onOpen, onMessage) {
    const socket = new WebSocket(url, ["mqtt"]);
    socket.binaryType = "arraybuffer";
    socket.addEventListener("open", (event) => onOpen());
    //socket.addEventListener("error", (event) => onError(event.toString()));

    socket.addEventListener("message", (event) => {
        // TODO: Error if text
        onMessage(new BitArray(new Uint8Array(event.data)));
    });

    return socket;
}

export function send(socket, bitArray) {
    // TODO: This is not safe
    socket.send(bitArray.rawBuffer);
}
