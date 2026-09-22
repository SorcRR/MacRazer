/* Scroll-driven 3D wireframe of the mouse. Vanilla canvas, no dependencies.
   The shell is a lofted surface: a superellipse cross-section swept along the
   length, with the half-width and height tables traced off photos of the real
   mouse. Detail is placed in real coordinates and the surface angle solved for,
   because the shell is flat on top and steep at the flanks, so equal steps in
   angle are wildly unequal steps in millimetres. */
(function () {
  var canvas = document.getElementById("wireframe");
  if (!canvas || !canvas.getContext) return;
  var ctx = canvas.getContext("2d");
  var PI = Math.PI;

  /* ---------- proportions (119.6 x 62.5 x 38.1 mm, length normalised to 1) ---------- */
  var HALF_W = 0.261;
  var HEIGHT = 0.318;

  /* half-width, traced off the underside photo: narrow blunt nose, wings flaring
     hard by 7%, near-parallel flanks, widest at ~68%, rounded tail */
  var W_TABLE = [[0, 0.30], [0.03, 0.72], [0.07, 0.90], [0.13, 0.92], [0.22, 0.92],
                 [0.33, 0.89], [0.45, 0.91], [0.56, 0.95], [0.68, 1.00], [0.79, 0.96],
                 [0.88, 0.83], [0.94, 0.63], [0.98, 0.36], [1, 0.10]];

  function spline(t, x) {
    var n = t.length;
    if (x <= t[0][0]) return t[0][1];
    if (x >= t[n - 1][0]) return t[n - 1][1];
    var i = 0;
    while (i < n - 2 && x > t[i + 1][0]) i++;
    var p0 = t[i], p1 = t[i + 1];
    var pm = t[i > 0 ? i - 1 : 0], pp = t[i + 2 < n ? i + 2 : n - 1];
    var dx = p1[0] - p0[0];
    var m0 = (p1[1] - pm[1]) / (p1[0] - pm[0]) * dx;
    var m1 = (pp[1] - p0[1]) / (pp[0] - p0[0]) * dx;
    var s = (x - p0[0]) / dx, s2 = s * s, s3 = s2 * s;
    return (2 * s3 - 3 * s2 + 1) * p0[1] + (s3 - 2 * s2 + s) * m0 +
           (-2 * s3 + 3 * s2) * p1[1] + (s3 - s2) * m1;
  }

  var Y_MID = 0.42 * HEIGHT;
  var FLOOR = -Y_MID;

  function halfW(v) { return spline(W_TABLE, v) * HALF_W; }
  /* Height is one clean arch rather than a table of points: the nose lip climbs
     almost vertically, the rate eases off into the crown just past the middle, then
     the shell falls away across the whole back half. Both halves flatten to zero
     slope at the crown, so it meets smoothly and cannot wiggle or overshoot. */
  var LIP = 0.18;        /* height at the very nose, as a fraction of the crown */
  var CROWN = 0.57;      /* where the crown sits along the length */
  var RISE = 2.0;        /* how quickly the climb eases off */
  var FALL = 2.5;        /* how quickly the tail falls away */

  function tall(v) {
    var h;
    if (v <= CROWN) h = LIP + (1 - LIP) * (1 - Math.pow(1 - v / CROWN, RISE));
    else h = 1 - 0.98 * Math.pow((v - CROWN) / (1 - CROWN), FALL);
    return h * HEIGHT;
  }
  function power(v) { return (3.5 - 0.5 * v) / 2; }   /* boxy shell, flat crown */

  /* phi: 0 = right edge on the desk, PI/2 = top centre, PI = left edge */
  function surf(v, phi) {
    var e = 1 / power(v);
    var c = Math.cos(phi), s = Math.sin(phi);
    return [(c < 0 ? -1 : 1) * halfW(v) * Math.pow(Math.abs(c), e),
            tall(v) * Math.pow(Math.abs(s), e) - Y_MID,
            v - 0.5];
  }

  /* solve the surface angle for a real x, or a real height up the flank */
  function atX(v, x) {
    var a = Math.acos(Math.pow(Math.min(1, Math.abs(x) / halfW(v)), power(v)));
    return surf(v, x < 0 ? PI - a : a);
  }
  function atY(v, y, left) {
    var a = Math.asin(Math.pow(Math.min(1, y / tall(v)), power(v)));
    return surf(v, left ? PI - a : a);
  }

  /* ---------- geometry ---------- */
  var mesh = [], detail = [], i, j, t, v, x, line;

  for (i = 0; i < 11; i++) {                       /* longitudes, nose to tail */
    for (line = [], j = 0; j <= 52; j++) line.push(surf(0.985 * j / 52, PI * i / 10));
    mesh.push(line);
  }
  for (i = 0; i <= 17; i++) {                      /* cross sections */
    for (line = [], j = 0; j <= 30; j++) line.push(surf(i / 17, PI * j / 30));
    mesh.push(line);
  }

  function runX(xx, v0, v1, n) {                   /* line held at a real x */
    for (var l = [], q = 0; q <= n; q++) l.push(atX(v0 + (v1 - v0) * q / n, xx));
    return l;
  }
  function runY(yy, v0, v1, left, n) {             /* line held at a real height */
    for (var l = [], q = 0; q <= n; q++) l.push(atY(v0 + (v1 - v0) * q / n, yy, left));
    return l;
  }

  /* rounded rectangle in [0,1]^2, with its own corner radius per axis so a long
     shallow pad can keep properly round end caps instead of turning into an oval */
  function unitLoop(ra, rb) {
    if (rb === undefined) rb = ra;
    var pts = [], c = [[1 - ra, 1 - rb, 0], [ra, 1 - rb, PI / 2],
                       [ra, rb, PI], [1 - ra, rb, 1.5 * PI]], q, s, a;
    for (q = 0; q < 4; q++) {
      for (s = 0; s <= 6; s++) {
        a = c[q][2] + PI / 2 * (s / 6);
        pts.push([c[q][0] + ra * Math.cos(a), c[q][1] + rb * Math.sin(a)]);
      }
    }
    pts.push(pts[0]);
    return pts;
  }
  function padX(v0, v1, x0, x1, ra, rb) {          /* outline on the top surface */
    return unitLoop(ra, rb).map(function (p) {
      return atX(v0 + (v1 - v0) * p[0], x0 + (x1 - x0) * p[1]);
    });
  }
  /* thumb pad on the left flank: a capsule that tilts along the flank and tapers,
     the way the real pads are cut */
  function thumbPad(v0, v1, y0, y1, slant, taper, ra, rb) {
    return unitLoop(ra, rb).map(function (p) {
      var a = p[0];
      var half = (y1 - y0) / 2 * (1 + taper * (a - 0.5));
      var mid = (y0 + y1) / 2 + slant * (a - 0.5);
      return atY(v0 + (v1 - v0) * a, mid - half + 2 * half * p[1], true);
    });
  }

  /* ---------- the top ---------- */
  var CH = 0.015;                                  /* half-width of the button channel */
  detail.push(runX(CH, 0.015, 0.120, 10));
  detail.push(runX(-CH, 0.015, 0.120, 10));
  detail.push(runX(CH, 0.232, 0.478, 14));
  detail.push(runX(-CH, 0.232, 0.478, 14));
  detail.push([atX(0.478, CH), atX(0.478, -CH)]);
  detail.push([atX(0.015, CH), atX(0.015, -CH)]);

  for (i = 0; i < 2; i++) {                        /* click-plate seams */
    for (line = [], j = 0; j <= 40; j++) {
      t = j / 40;
      v = 0.015 + 0.465 * t;
      var blend = t < 0.45 ? 0 : Math.pow((t - 0.45) / 0.55, 1.35);
      x = 0.93 * halfW(v) * (1 - blend) + CH * blend;
      line.push(atX(v, i ? -x : x));
    }
    detail.push(line);
  }

  detail.push(runY(0.055, 0.03, 0.962, false, 34)); /* shell-to-chassis parting line */
  detail.push(runY(0.055, 0.03, 0.962, true, 34));

  /* thumb buttons: long shallow capsules tilted up toward the tail, tapering
     opposite ways so the pair reads as the shallow chevron in the photo */
  detail.push(thumbPad(0.342, 0.477, 0.154, 0.203, 0.007, 0.22, 0.16, 0.44));
  detail.push(thumbPad(0.354, 0.465, 0.161, 0.196, 0.007, 0.22, 0.18, 0.42));
  detail.push(thumbPad(0.497, 0.632, 0.159, 0.207, 0.006, -0.18, 0.16, 0.44));
  detail.push(thumbPad(0.509, 0.620, 0.166, 0.200, 0.006, -0.18, 0.18, 0.42));
  detail.push(padX(0.300, 0.396, -0.022, 0.022, 0.23, 0.46));  /* DPI button */

  (function port() {                               /* USB-C mouth in the nose */
    detail.push(unitLoop(0.45).map(function (p) {
      return [-0.030 + 0.060 * p[0], 0.030 + 0.030 * p[1] - Y_MID, -0.492];
    }));
  })();

  (function wheel() {                              /* slot, rims and knurl */
    var vc = 0.175, r = 0.046, half = 0.013;
    var yc = tall(vc) - Y_MID + 0.016 - r, zc = vc - 0.5, rims = [], rim, a, q;
    detail.push(padX(0.122, 0.232, -0.021, 0.021, 0.46));
    for (q = 0; q < 2; q++) {
      for (rim = [], j = 0; j <= 32; j++) {
        a = 2 * PI * j / 32;
        rim.push([q ? half : -half, yc + r * Math.sin(a), zc + r * Math.cos(a)]);
      }
      detail.push(rim);
      rims.push(rim);
    }
    for (j = 0; j < 32; j += 2) detail.push([rims[0][j], rims[1][j]]);
  })();

  /* ---------- the underside ---------- */
  function onFloor(pts) {
    return pts.map(function (p) { return [p[0], FLOOR, p[1] - 0.5]; });
  }
  /* both take the length range first, matching padX / thumbPad / runX */
  function floorRect(v0, v1, x0, x1, rad) {
    return onFloor(unitLoop(rad).map(function (p) {
      return [x0 + (x1 - x0) * p[1], v0 + (v1 - v0) * p[0]];
    }));
  }
  function floorDisc(cv, cx, r, n) {
    for (var l = [], q = 0; q <= n; q++) {
      l.push([cx + r * Math.cos(2 * PI * q / n), cv + r * Math.sin(2 * PI * q / n)]);
    }
    return onFloor(l);
  }
  function floorBand(edge, n) {                    /* strip between two parametric edges */
    var l = [], q;
    for (q = 0; q <= n; q++) l.push(edge(q / n, 0));
    for (q = n; q >= 0; q--) l.push(edge(q / n, 1));
    l.push(l[0]);
    return onFloor(l);
  }

  detail.push(floorRect(0.430, 0.545, -0.052, 0.052, 0.32));   /* sensor window */
  detail.push(floorDisc(0.487, 0, 0.026, 20));                 /* lens */
  detail.push(floorRect(0.434, 0.520, 0.104, 0.156, 0.42));    /* BT / off / 2.4 slider */
  detail.push(floorDisc(0.478, 0.130, 0.015, 14));             /* slider nub */
  detail.push(floorDisc(0.468, -0.095, 0.026, 18));            /* profile button */
  detail.push(floorDisc(0.424, -0.095, 0.006, 10));            /* status LED */
  detail.push(floorDisc(0.765, 0, 0.170, 44));                 /* battery hatch */
  for (i = 0; i < 3; i++) {                                    /* hatch grip dots */
    detail.push(floorDisc(0.700, -0.052 + 0.020 * i, 0.006, 8));
    detail.push(floorDisc(0.700, 0.032 + 0.020 * i, 0.006, 8));
  }

  detail.push(floorBand(function (s, edge) {                   /* front PTFE foot */
    var u = -0.80 + 1.60 * s;
    return [u * 0.235, edge ? 0.250 + 0.048 * u * u : 0.132 + 0.072 * u * u];
  }, 22));
  for (i = 0; i < 2; i++) {                                    /* rear PTFE feet */
    detail.push(floorBand((function (side) {
      return function (s, edge) {
        var vv = 0.775 + 0.165 * s, w = halfW(vv) * 0.86;
        return [side ? -(edge ? w - 0.075 : w) : (edge ? w - 0.075 : w), vv];
      };
    })(i), 16));
  }

  /* ---------- rotation ----------
     A fixed opening pose, then yaw, pitch and roll each advance with the scroll
     at their own rate. The rates are re-rolled every load, so the tumble takes a
     different path each visit; the pose is a pure function of scroll position, so
     scrolling back to the top always lands on the opening pose again. */
  var BASE = [0.26, 0.60, 0.17];
  function rate(base) {
    return base * (0.7 + Math.random() * 0.6) * (Math.random() < 0.5 ? -1 : 1);
  }
  var RATE = [rate(0.44), rate(1.0), rate(0.29)];

  function mul(a, b) {
    var m = [[0, 0, 0], [0, 0, 0], [0, 0, 0]], r, q, n, s;
    for (r = 0; r < 3; r++) {
      for (q = 0; q < 3; q++) {
        for (s = 0, n = 0; n < 3; n++) s += a[r][n] * b[n][q];
        m[r][q] = s;
      }
    }
    return m;
  }

  var PITCH = 0.40, ROLL = -0.09;
  var cp = Math.cos(PITCH), sp = Math.sin(PITCH);
  var cr = Math.cos(ROLL), sr = Math.sin(ROLL);
  var V = [[cr, -sr * cp, sr * sp],
           [sr, cr * cp, -cr * sp],
           [0, sp, cp]];

  var DIST = 3.15, FOCAL = 3.15, RADIUS = 0.62, BUCKETS = 9;
  var colour = "79,224,122";
  var cssW = 0, cssH = 0, scale = 1, ox = 0, oy = 0;

  function resize() {
    var r = canvas.getBoundingClientRect();
    if (!r.width || !r.height) { cssW = 0; return false; }
    var dpr = Math.min(window.devicePixelRatio || 1, 2);
    cssW = r.width; cssH = r.height;
    canvas.width = Math.round(cssW * dpr);
    canvas.height = Math.round(cssH * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    scale = Math.min(cssW * 0.82, cssH * 0.60);
    ox = cssW / 2; oy = cssH / 2;
    var c = getComputedStyle(canvas).color.match(/\d+/g);
    if (c && c.length >= 3) colour = c[0] + "," + c[1] + "," + c[2];
    return true;
  }

  var sx = [], sy = [], sd = [];

  function stroke(lines, M, alpha, width) {
    var paths = [], b;
    for (b = 0; b < BUCKETS; b++) paths.push(new Path2D());
    for (var n = 0; n < lines.length; n++) {
      var pts = lines[n], len = pts.length, q;
      for (q = 0; q < len; q++) {
        var p = pts[q];
        var px = M[0][0] * p[0] + M[0][1] * p[1] + M[0][2] * p[2];
        var py = M[1][0] * p[0] + M[1][1] * p[1] + M[1][2] * p[2];
        var pz = M[2][0] * p[0] + M[2][1] * p[1] + M[2][2] * p[2];
        var f = FOCAL / (DIST - pz) * scale;
        sx[q] = ox + px * f; sy[q] = oy - py * f; sd[q] = pz;
      }
      for (q = 0; q < len - 1; q++) {
        var d = (sd[q] + sd[q + 1]) * 0.5;
        b = Math.round((d + RADIUS) / (2 * RADIUS) * (BUCKETS - 1));
        b = b < 0 ? 0 : b > BUCKETS - 1 ? BUCKETS - 1 : b;
        paths[b].moveTo(sx[q], sy[q]);
        paths[b].lineTo(sx[q + 1], sy[q + 1]);
      }
    }
    for (b = 0; b < BUCKETS; b++) {
      var f2 = b / (BUCKETS - 1);
      ctx.strokeStyle = "rgba(" + colour + "," + (alpha * (0.26 + 0.74 * f2)).toFixed(3) + ")";
      ctx.lineWidth = width * (0.75 + 0.45 * f2);
      ctx.stroke(paths[b]);
    }
  }

  function draw(angle) {
    if (!cssW) return;
    var ax = BASE[0] + angle * RATE[0];
    var ay = BASE[1] + angle * RATE[1];
    var az = BASE[2] + angle * RATE[2];
    var cx = Math.cos(ax), s1 = Math.sin(ax);
    var cy = Math.cos(ay), s2 = Math.sin(ay);
    var cz = Math.cos(az), s3 = Math.sin(az);
    var M = mul(V, mul([[cz, -s3, 0], [s3, cz, 0], [0, 0, 1]],
                mul([[cy, 0, s2], [0, 1, 0], [-s2, 0, cy]],
                    [[1, 0, 0], [0, cx, -s1], [0, s1, cx]])));
    ctx.clearRect(0, 0, cssW, cssH);
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    stroke(mesh, M, 0.55, 1);
    stroke(detail, M, 1, 1.35);
  }

  /* ---------- scroll drive ---------- */
  var still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var TURN = 2 * PI / 2400;                        /* one yaw turn per 2400px scrolled */
  var target = 0, current = 0, running = false;

  function aim() {
    var y = window.pageYOffset || document.documentElement.scrollTop || 0;
    target = (y < 1 ? 0 : y) * TURN;             /* fractional offsets still count as the top */
  }

  function frame() {
    var delta = target - current;
    if (Math.abs(delta) <= 0.0004) {             /* land exactly on the target, so the
                                                    top of the page is always the same pose */
      current = target;
      draw(current);
      running = false;
      return;
    }
    current += delta * 0.11;
    draw(current);
    requestAnimationFrame(frame);
  }

  function kick() {
    if (!cssW) return;                           /* hidden on narrow screens: no loop at all */
    aim();
    if (!running) { running = true; requestAnimationFrame(frame); }
  }

  function start() {
    resize();                                      /* may be display:none on a narrow window */
    if (still) { draw(current); return; }          /* the opening pose, and it stays there */
    aim();
    current = target;
    draw(current);
    window.addEventListener("scroll", kick, { passive: true });
  }

  window.addEventListener("resize", function () {
    if (!resize()) return;
    if (!still) aim();
    draw(current);                               /* setting canvas.width wiped the bitmap,
                                                    so repaint now rather than waiting for
                                                    a frame that may be throttled */
    if (!still) kick();                          /* then ease to wherever the scroll now is */
  });
  start();
})();
