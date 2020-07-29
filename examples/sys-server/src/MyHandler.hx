package;

import hx.ws.SocketImpl;
import hx.ws.WebSocketHandler;
import hx.ws.Types;

class MyHandler extends WebSocketHandler {
    public function new(s: SocketImpl) {
        super(s);
        onopen = function() {
            trace(id + ". OPEN");
        }
        onclose = function() {
            trace(id + ". CLOSE");
        }
        onmessage = function(message: MessageType) {
            switch (message) {
                case BytesMessage(content):
                    send(content);
                case StrMessage(content):
                    send("echo: " + content);
            }
        }
        onerror = function(error) {
            trace(id + ". ERROR: " + error);
        }
    }
}
