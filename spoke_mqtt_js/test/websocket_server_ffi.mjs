import { WebSocketServer } from 'ws';
import {
    BitArray
} from "./gleam.mjs";


export function start(port, onConnected, onMessage, onClose) {
    const wss = new WebSocketServer({ port: port });
    const sockets = [];

    wss.on('connection', function connection(ws) {
        sockets.push(ws);

        onConnected((bitArray) => {
            ws.send(bitArray.rawBuffer)
        });

        ws.on('message', function message(data) {
            onMessage(new BitArray(new Uint8Array(data)));
        });

        ws.on('close', onClose);
    });

    return () => {
        sockets.forEach(socket => socket.close());
        wss.close();
    }
}

