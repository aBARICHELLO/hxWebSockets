package hx.ws;

import haxe.io.Bytes;
import haxe.io.Error;

class WebSocketCommon {
    private static var _nextId:Int = 1;
    public var id:Int;
    public var state:HandlerState = HandlerState.Handshake;
    
    private var _socket:SocketImpl;
    
    private var _onopenCalled:Null<Bool> = null;
    private var _lastError:Dynamic = null;
    
    public var onopen:Void->Void;
    public var onclose:Void->Void;
    public var onerror:Dynamic->Void;
    public var onmessage:Dynamic->Void;
    
    private var _buffer:Buffer = new Buffer();
    
    public function new(socket:SocketImpl = null) {
        id = _nextId++;
        if (socket == null) {
            _socket = new SocketImpl();
            _socket.setBlocking(false);
        } else {
            _socket = socket;
        }
    }
    
    public function send(data:Any) {
        Log.data(data, id);
        if (Std.is(data, String)) {
            sendFrame(Utf8Encoder.encode(data), OpCode.Text);
        } else if (Std.is(data, Bytes)) {
            sendFrame(data, OpCode.Binary);
        }
    }
    
    private function sendFrame(data:Bytes, type:OpCode) {
        writeBytes(prepareFrame(data, type, true));
    }

    private var _isFinal:Bool;
    private var _isMasked:Bool;
    private var _opcode:OpCode;
    private var _frameIsBinary:Bool;
    private var _partialLength:Int;
    private var _length:Int;
    private var _mask:Bytes;
    private var _payload:Buffer = null;
    private var _lastPong:Date = null;
    
    private function handleData() {
        switch (state) {
            case HandlerState.Head:
                if (_buffer.available < 2) return;
                
                var b0 = _buffer.readByte();
                var b1 = _buffer.readByte();

                _isFinal = ((b0 >> 7) & 1) != 0;
                _opcode = cast(((b0 >> 0) & 0xF), OpCode);
                _frameIsBinary = if (_opcode == OpCode.Text) false; else if (_opcode == OpCode.Binary) true; else _frameIsBinary;
                _partialLength = ((b1 >> 0) & 0x7F);
                _isMasked = ((b1 >> 7) & 1) != 0;

                state = HandlerState.HeadExtraLength;
                handleData(); // may be more data
            case HandlerState.HeadExtraLength:
                if (_partialLength == 126) {
                    if (_buffer.available < 2) return;
                    _length = _buffer.readUnsignedShort();
                } else if (_partialLength == 127) {
                    if (_buffer.available < 8) return;
                    var tmp = _buffer.readUnsignedInt();
                    if(tmp != 0) throw 'message too long';
                    _length = _buffer.readUnsignedInt();
                } else {
                    _length = _partialLength;
                }
                state = HandlerState.HeadExtraMask;
                handleData(); // may be more data
            case HandlerState.HeadExtraMask:
                if (_isMasked) {
                    if (_buffer.available < 4) return;
                    _mask = _buffer.readBytes(4);
                }
                state = HandlerState.Body;
                handleData(); // may be more data
            case HandlerState.Body:
                if (_buffer.available < _length) return;
                if (_payload == null) {
                    _payload = new Buffer();
                }
                _payload.writeBytes(_buffer.readBytes(_length));

                switch (_opcode) {
                    case OpCode.Binary | OpCode.Text | OpCode.Continuation:
                        if (_isFinal) {
                            var messageData = _payload.readAllAvailableBytes();
                            var unmaskedMessageData = (_isMasked) ? applyMask(messageData, _mask) : messageData;
                            if (_frameIsBinary) {
                                if (this.onmessage != null) {
                                    this.onmessage({
                                        data: unmaskedMessageData
                                    });
                                }
                            } else {
                                var stringPayload = Utf8Encoder.decode(unmaskedMessageData);
                                Log.data(stringPayload, id);
                                if (this.onmessage != null) {
                                    this.onmessage({
                                        data: stringPayload
                                    });
                                }
                            }
                            _payload = null;
                        }
                    case OpCode.Ping:
                        sendFrame(_payload.readAllAvailableBytes(), OpCode.Pong);
                    case OpCode.Pong:
                        _lastPong = Date.now();
                    case OpCode.Close:
                        close();
                }
                
                if (state != HandlerState.Closed) state = HandlerState.Head;
                handleData(); // may be more data
            case HandlerState.Closed:
                close();
            case _:
                trace('State not impl: ${state}');
        }
    }
    
    public function close() {
        if (state != HandlerState.Closed) {
            try {
                Log.debug("Closed", id);
                sendFrame(Bytes.alloc(0), OpCode.Close);
                state = HandlerState.Closed;
                _socket.close();
            } catch (e:Dynamic) { }
            
            if (onclose != null) {
                onclose();
            }
        }
    }
    
    private function writeBytes(data:Bytes) {
        try {
            _socket.output.write(data);
            _socket.output.flush();
        } catch (e:Dynamic) {
            Log.debug(e, id);
            if (onerror != null) {
                onerror(Std.string(e));
            }
        }
    }
    
    private function prepareFrame(data:Bytes, type:OpCode, isFinal:Bool):Bytes {
        var out = new Buffer();
        var isMasked = false; // All clientes messages must be masked: http://tools.ietf.org/html/rfc6455#section-5.1
        var mask = generateMask();
        var sizeMask = (isMasked ? 0x80 : 0x00);

        out.writeByte(type.toInt() | (isFinal ? 0x80 : 0x00));

        if (data.length < 126) {
            out.writeByte(data.length | sizeMask);
        } else if (data.length < 65536) {
            out.writeByte(126 | sizeMask);
            out.writeShort(data.length);
        } else {
            out.writeByte(127 | sizeMask);
            out.writeInt(0);
            out.writeInt(data.length);
        }

        if (isMasked) out.writeBytes(mask);

        out.writeBytes(isMasked ? applyMask(data, mask) : data);
        return out.readAllAvailableBytes();
    }

    private static function generateMask() {
        var maskData = Bytes.alloc(4);
        maskData.set(0, Std.random(256));
        maskData.set(1, Std.random(256));
        maskData.set(2, Std.random(256));
        maskData.set(3, Std.random(256));
        return maskData;
    }
    
    private static function applyMask(payload:Bytes, mask:Bytes) {
        var maskedPayload = Bytes.alloc(payload.length);
        for (n in 0 ... payload.length) maskedPayload.set(n, payload.get(n) ^ mask.get(n % mask.length));
        return maskedPayload;
    }
    
    private function process() {
        if (_onopenCalled == false) {
            _onopenCalled = true;
            if (onopen != null) {
                onopen();
            }
        }
        
        if (_lastError != null) {
            var error = _lastError;
            _lastError = null;
            if (onerror != null) {
                onerror(error);
            }
        }
        
        var needClose = false;
        var result = null;
        try {
            result = sys.net.Socket.select([_socket], null, null, 0.01);
        } catch (e:Dynamic) {
            needClose = true;
        }
        
        if (result != null && needClose == false) {
            if (result.read.length > 0) {
                try {
                    while (true) {
                        var data = Bytes.alloc(1024);
                        var read = _socket.input.readBytes(data, 0, data.length);
                        if (read <= 0){
                            break;
                        }
                        Log.debug("Bytes read: " + read, id);
                        _buffer.writeBytes(data.sub(0, read));
                    }
                } catch (e:Dynamic) {
                    needClose = !(e == 'Blocking' || (Std.is(e, Error) && (e:Error).match(Error.Blocked)));
                }
                
                if (needClose == false) {
                    handleData();
                }
            }
        }
        
        if (needClose == true) { // dont want to send the Close frame here
            if (state != HandlerState.Closed) {
                try {
                    Log.debug("Closed", id);
                    state = HandlerState.Closed;
                    _socket.close();
                } catch (e:Dynamic) { }
                
                if (onclose != null) {
                    onclose();
                }
            }
        }
    }
    
    public function sendHttpRequest(httpRequest:HttpRequest) {
        var data = httpRequest.build();
        
        Log.data(data, id);
        
        _socket.output.write(Bytes.ofString(data));
        _socket.output.flush();
    }
    
    public function sendHttpResponse(httpResponse:HttpResponse) {
        var data = httpResponse.build();
        
        Log.data(data, id);
        
        _socket.output.write(Bytes.ofString(data));
        _socket.output.flush();
    }
    
    public function recvHttpRequest():HttpRequest {
        if (!_buffer.endsWith("\r\n\r\n")) {
            return null;
        }
        
        var httpRequest = new HttpRequest();
        while (true) {
            var line = _buffer.readLine();
            if (line == null || line == "") {
                break;
            }
            httpRequest.addLine(line);
            
        }
        
        Log.data(httpRequest.toString(), id);
        
        return httpRequest;
    }
    
    public function recvHttpResponse():HttpResponse {
        if (!_buffer.endsWith("\r\n\r\n")) {
            return null;
        }
        
        var httpResponse = new HttpResponse();
        while (true) {
            var line = _buffer.readLine();
            if (line == null || line == "") {
                break;
            }
            httpResponse.addLine(line);
            
        }
        
        Log.data(httpResponse.toString(), id);
        
        return httpResponse;
    }
    
}