var r,e={exports:{}};
/*!
 * vary
 * Copyright(c) 2014-2017 Douglas Christopher Wilson
 * MIT Licensed
 */function t(){if(r)return e.exports;r=1,e.exports=function(r,e){if(!r||!r.getHeader||!r.setHeader)throw new TypeError("res argument is required");var t=r.getHeader("Vary")||"",a=Array.isArray(t)?t.join(", "):String(t);(t=n(a,e))&&r.setHeader("Vary",t)},e.exports.append=n;var t=/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;function n(r,e){if("string"!=typeof r)throw new TypeError("header argument is required");if(!e)throw new TypeError("field argument is required");for(var n=Array.isArray(e)?e:a(String(e)),i=0;i<n.length;i++)if(!t.test(n[i]))throw new TypeError("field argument contains an invalid header name");if("*"===r)return r;var o=r,s=a(r.toLowerCase());if(-1!==n.indexOf("*")||-1!==s.indexOf("*"))return"*";for(var u=0;u<n.length;u++){var f=n[u].toLowerCase();-1===s.indexOf(f)&&(s.push(f),o=o?o+", "+n[u]:n[u])}return o}function a(r){for(var e=0,t=[],n=0,a=0,i=r.length;a<i;a++)switch(r.charCodeAt(a)){case 32:n===e&&(n=e=a+1);break;case 44:t.push(r.substring(n,e)),n=e=a+1;break;default:e=a+1}return t.push(r.substring(n,e)),t}return e.exports}export{t as r};
//# sourceMappingURL=index-CA1hoRnQ.js.map
