(function() {
  "use strict";
  var url = "ws://" + location.host + "/__wig/ws";
  var reconnectMs = 1000;

  function connect() {
    var ws = new WebSocket(url);
    ws.onmessage = function(e) {
      var msg = JSON.parse(e.data);
      if (msg.command === "reload") location.reload();
      if (msg.command === "error") console.error("[wig]", msg.message);
    };
    ws.onclose = function() {
      setTimeout(connect, reconnectMs);
    };
  }

  connect();
})();
