// Animated live-code demo for the hero card. Language-agnostic.
(function () {
  var reduce = matchMedia("(prefers-reduced-motion:reduce)").matches;
  var rows = [].slice.call(document.querySelectorAll("#demo .row"));
  if (!rows.length) return;
  var C = 2 * Math.PI * 15;                       // ring circumference (r=15)
  var seeds = rows.map(function (_, i) { return 100000 + i * 48271; });

  function code(n) { return ("00000" + (n % 1e6)).slice(-6).replace(/(\d{3})(\d{3})/, "$1 $2"); }
  function color(frac) {                           // fresh blue -> expiring red
    var cs = getComputedStyle(document.documentElement);
    if (frac > 0.27) return (cs.getPropertyValue("--accent") || "#0a84ff").trim();
    if (frac > 0.13) return "#ff9f0a";
    return (cs.getPropertyValue("--warn") || "#ff453a").trim();
  }
  rows.forEach(function (r) { r.querySelector(".prg").style.strokeDasharray = C; });

  function tick() {
    var period = 30, now = Date.now() / 1000, rem = period - (now % period), frac = rem / period;
    var cycle = Math.floor(now / period);
    rows.forEach(function (r, i) {
      var prg = r.querySelector(".prg"), dig = r.querySelector(".digits");
      prg.style.strokeDashoffset = C * (1 - frac);
      var c = color(frac); prg.style.stroke = c; dig.style.color = c;
      dig.textContent = code(seeds[i] + cycle * 7919 * (i + 1));
    });
    if (!reduce) requestAnimationFrame(tick);
  }
  tick();
})();
