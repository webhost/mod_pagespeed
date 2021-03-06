(function(){var pagespeedutils = {MAX_POST_SIZE:131072, sendBeacon:function(beaconUrl, htmlUrl, data) {
  var httpRequest;
  if (window.XMLHttpRequest) {
    httpRequest = new XMLHttpRequest;
  } else {
    if (window.ActiveXObject) {
      try {
        httpRequest = new ActiveXObject("Msxml2.XMLHTTP");
      } catch (e) {
        try {
          httpRequest = new ActiveXObject("Microsoft.XMLHTTP");
        } catch (e2) {
        }
      }
    }
  }
  if (!httpRequest) {
    return!1;
  }
  httpRequest.open("POST", beaconUrl + (-1 == beaconUrl.indexOf("?") ? "?" : "&") + "url=" + encodeURIComponent(htmlUrl));
  httpRequest.setRequestHeader("Content-Type", "application/x-www-form-urlencoded");
  httpRequest.send(data);
  return!0;
}, addHandler:function(elem, eventName, func) {
  if (elem.addEventListener) {
    elem.addEventListener(eventName, func, !1);
  } else {
    if (elem.attachEvent) {
      elem.attachEvent("on" + eventName, func);
    } else {
      var oldHandler = elem["on" + eventName];
      elem["on" + eventName] = function() {
        func.call(this);
        oldHandler && oldHandler.call(this);
      };
    }
  }
}, getPosition:function(element) {
  for (var top = element.offsetTop, left = element.offsetLeft;element.offsetParent;) {
    element = element.offsetParent, top += element.offsetTop, left += element.offsetLeft;
  }
  return{top:top, left:left};
}, getWindowSize:function() {
  return{height:window.innerHeight || document.documentElement.clientHeight || document.body.clientHeight, width:window.innerWidth || document.documentElement.clientWidth || document.body.clientWidth};
}, inViewport:function(element, windowSize) {
  return pagespeedutils.positionInViewport(pagespeedutils.getPosition(element), windowSize);
}, positionInViewport:function(pos, windowSize) {
  return pos.top < windowSize.height && pos.left < windowSize.width;
}, getRequestAnimationFrame:function() {
  return window.requestAnimationFrame || window.webkitRequestAnimationFrame || window.mozRequestAnimationFrame || window.oRequestAnimationFrame || window.msRequestAnimationFrame || null;
}};
pagespeedutils.CriticalXPaths = function(viewportWidth, viewportHeight) {
  this.windowSize_ = {height:viewportHeight, width:viewportWidth};
};
pagespeedutils.generateXPath = function(node, doc) {
  for (var xpathUnits = [];node != doc.body;) {
    var id = node.getAttribute("id");
    if (id && 1 == doc.querySelectorAll("#" + id).length) {
      xpathUnits.unshift(node.tagName.toLowerCase() + '[@id="' + node.getAttribute("id") + '"]');
      break;
    } else {
      for (var i = 0, sibling = node;sibling;sibling = sibling.previousElementSibling) {
        "SCRIPT" !== sibling.tagName && "NOSCRIPT" !== sibling.tagName && "STYLE" !== sibling.tagName && "LINK" !== sibling.tagName && ++i;
      }
      xpathUnits.unshift(node.tagName.toLowerCase() + "[" + i + "]");
    }
    node = node.parentNode;
  }
  return xpathUnits.length ? xpathUnits.join("/") : "";
};
window.pagespeed = window.pagespeed || {};
var pagespeed = window.pagespeed;
pagespeed.SplitHtmlBeacon = function(beaconUrl, htmlUrl, optionsHash, nonce) {
  this.btfNodes_ = [];
  this.beaconUrl_ = beaconUrl;
  this.htmlUrl_ = htmlUrl;
  this.optionsHash_ = optionsHash;
  this.nonce_ = nonce;
  this.windowSize_ = pagespeedutils.getWindowSize();
};
pagespeed.SplitHtmlBeacon.prototype.walkDom_ = function(node) {
  for (var allChildrenBtf = !0, btfChildren = [], currChild = node.firstChild;null != currChild;currChild = currChild.nextSibling) {
    currChild.nodeType === Node.ELEMENT_NODE && "SCRIPT" != currChild.tagName && "NOSCRIPT" != currChild.tagName && "STYLE" != currChild.tagName && "LINK" != currChild.tagName && (this.walkDom_(currChild) ? btfChildren.push(currChild) : allChildrenBtf = !1);
  }
  if (allChildrenBtf && !pagespeedutils.inViewport(node, this.windowSize_)) {
    return!0;
  }
  for (var i = 0;i < btfChildren.length;++i) {
    this.btfNodes_.push(pagespeedutils.generateXPath(btfChildren[i], window.document));
  }
  return!1;
};
pagespeed.SplitHtmlBeacon.prototype.checkSplitHtml_ = function() {
  this.walkDom_(document.body);
  if (0 != this.btfNodes_.length) {
    for (var data = "oh=" + this.optionsHash_ + "&n=" + this.nonce_, data = data + ("&xp=" + encodeURIComponent(this.btfNodes_[0])), i = 1;i < this.btfNodes_.length;++i) {
      var tmp = "," + encodeURIComponent(this.btfNodes_[i]);
      if (data.length + tmp.length > pagespeedutils.MAX_POST_SIZE) {
        break;
      }
      data += tmp;
    }
    pagespeedutils.sendBeacon(this.beaconUrl_, this.htmlUrl_, data);
  }
};
pagespeed.splitHtmlBeaconInit = function(beaconUrl, htmlUrl, optionsHash, nonce) {
  var temp = new pagespeed.SplitHtmlBeacon(beaconUrl, htmlUrl, optionsHash, nonce);
  pagespeedutils.addHandler(window, "load", function() {
    temp.checkSplitHtml_();
  });
};
pagespeed.splitHtmlBeaconInit = pagespeed.splitHtmlBeaconInit;
})();
