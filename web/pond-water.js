/* Rain on a reflecting garden pond. Cached sky, bounded drops and impact rings. */
(function (root) {
  'use strict';
  if (typeof document === 'undefined') return;
  const canvas = document.getElementById('pond-water');
  if (!canvas) return;
  const ctx = canvas.getContext('2d', {alpha:true});
  if (!ctx) return;
  const motion = root.matchMedia('(prefers-reduced-motion: reduce)');
  const sky = document.createElement('canvas'); sky.width=1200; sky.height=850;
  const paint = sky.getContext('2d');
  // An opaque backing prevents overlapping refracted strips from compounding
  // alpha into horizontal seams on WebView2's canvas compositor.
  const depth=paint.createLinearGradient(0,0,0,850);
  depth.addColorStop(0,'#a3c0b6'); depth.addColorStop(.38,'#e6ecda'); depth.addColorStop(.68,'#adc8bd'); depth.addColorStop(1,'#648f83');
  paint.fillStyle=depth;paint.fillRect(0,0,1200,850);
  function glow(x,y,rx,ry,color) {
    paint.save(); paint.translate(x,y); paint.scale(rx,ry);
    const g=paint.createRadialGradient(0,0,0,0,0,1);
    g.addColorStop(0,color); g.addColorStop(1,color.replace(/,[^,]+\)$/,',0)'));
    paint.fillStyle=g; paint.fillRect(-1,-1,2,2); paint.restore();
  }
  // Broad cloud reflections and cooler depths. The middle remains quiet for type.
  [[150,130,350,170],[750,100,460,170],[320,450,420,125],[1060,535,290,150],[650,790,540,90]].forEach(([x,y,rx,ry])=>glow(x,y,rx,ry,'rgba(255,255,239,.75)'));
  [[60,600,270,310],[1120,180,180,370],[900,820,320,110]].forEach(([x,y,rx,ry])=>glow(x,y,rx,ry,'rgba(36,93,81,.27)'));
  // Soft reflections of shore leaves, sparse and outside the reading area.
  paint.filter='blur(9px)';
  for (const side of [0,1]) for(let i=0;i<12;i++) {
    paint.save(); paint.translate(side ? 1215-i*9 : -20+i*10,170+i*56);
    paint.rotate((side ? -1 : 1)*(.45+Math.sin(i*2)*.45));
    paint.fillStyle=`rgba(78,121,100,${.045+(i%3)*.013})`; paint.beginPath();
    paint.ellipse(0,0,15+i%4*4,47+i%3*13,0,0,Math.PI*2); paint.fill(); paint.restore();
  }
  let width=0,height=0,frame=null,last=0,clock=0,lastWake=0;
  let pointer={x:.5,y:.5},drift={x:.5,y:.5};
  const wakes=[];
  const drops=Array.from({length:42},(_,i)=>({x:Math.random(),y:.15+Math.random()*.82,phase:Math.random(),speed:.30+Math.random()*.45,depth:.45+Math.random()*.55}));
  function impact(x,y,scale=1) { wakes.push({x,y,age:0,scale});if(wakes.length>55) wakes.shift(); }
  // Short separate runners frame the glass instead of covering the controls.
  const vines=document.createElement('div'); vines.className='pond-vines';vines.setAttribute('aria-hidden','true');
  const leaf='<path d="M0 0C-5-7-15-6-17-17L-8-14-7-24 0-19 7-24 8-14 17-17C15-6 5-7 0 0Z"/><path class="ivy-vein" d="M0 0V-19M0-7l-10-8M0-7l10-8"/>';
  vines.innerHTML=[['left','17%'],['left','59%'],['right','41%'],['right','77%']].map(([side,top],index)=>`<svg class="ivy-run ivy-${side}" style="top:${top};--vine-delay:${index*-1.7}s" viewBox="0 0 48 170"><path class="ivy-stem" d="M3 165C27 140 4 122 16 100S29 78 15 58 10 30 27 7"/>${[31,69,109,146].map((y,i)=>`<g class="ivy-leaf" transform="translate(${i%2?19:12} ${y}) rotate(${i%2?50:-45}) scale(${.62+i*.03})">${leaf}</g>`).join('')}<path class="ivy-tendril" d="M17 93q28-18 24-4t-9-5M14 47q23-13 20-22t-8 5"/></svg>`).join('');
  canvas.parentElement.appendChild(vines);
  function resize() {
    width=root.innerWidth; height=root.innerHeight;
    const ratio=Math.min(root.devicePixelRatio || 1,1.5);
    canvas.width=Math.round(width*ratio); canvas.height=Math.round(height*ratio);
    ctx.setTransform(ratio,0,0,ratio,0,0); draw(0); start();
  }
  function draw(delta) {
    clock+=delta;
    const t=clock/1000;
    drift.x+=(pointer.x-drift.x)*.025; drift.y+=(pointer.y-drift.y)*.025;
    ctx.clearRect(0,0,width,height);
    // Adjacent strips refract the cached sky by a few pixels, like shallow water.
    const strips=80;
    for(let i=0;i<strips;i++) {
      const v=i/strips;
      const offset=Math.sin(v*19-t*.14)*4+Math.sin(v*47+t*.19)*1.5+(drift.x-.5)*9;
      ctx.drawImage(sky,0,v*sky.height,sky.width,sky.height/strips+1,offset-12,v*height+(drift.y-.5)*4,width+24,height/strips+1);
    }
    // Sun catches short, irregular crests; never a wallpaper of concentric rings.
    for(let i=0;i<30;i++) {
      const x=((i*.381966)%1)*width, y=(.08+((i*.618034)%1)*.9)*height;
      const breath=(Math.sin(t*.24+i*1.7)+1)*.5;
      const length=(25+(i%5)*14)*(width/1200);
      ctx.beginPath();
      ctx.moveTo(x-length,y);
      ctx.bezierCurveTo(x-length*.4,y-2.5-breath*2,x+length*.4,y+4,x+length,y-1);
      const light=ctx.createLinearGradient(x-length,y,x+length,y);
      light.addColorStop(0,'rgba(255,255,244,0)');light.addColorStop(.48,`rgba(255,255,245,${.16+breath*.31})`);light.addColorStop(1,'rgba(255,255,244,0)');
      ctx.strokeStyle=light; ctx.lineWidth=.9; ctx.stroke();
    }
    if(!motion.matches) for(const drop of drops) {
      drop.phase+=delta/1000*drop.speed;
      if(drop.phase>=1) { impact(drop.x,drop.y,drop.depth);drop.phase%=1;drop.x=Math.random();drop.y=.15+Math.random()*.82; }
      const x=drop.x*width, y=drop.y*height-(1-drop.phase)*height*.48;
      const length=13+drop.depth*23;
      ctx.beginPath();ctx.moveTo(x+5,y-length);ctx.lineTo(x,y);
      ctx.strokeStyle=`rgba(244,255,245,${.18+drop.depth*.25})`;ctx.lineWidth=.6+drop.depth*.4;ctx.stroke();
    }
    for(let i=wakes.length-1;i>=0;i--) {
      const wake=wakes[i]; wake.age+=delta;
      if(wake.age>2900) { wakes.splice(i,1); continue; }
      const life=wake.age/2900, radius=(5+life*110)*(wake.scale||1);
      for(let ring=0;ring<3;ring++) {
        const r=radius-ring*12;if(r<3) continue;
        ctx.beginPath();ctx.ellipse(wake.x*width,wake.y*height,r,r*.32,0,0,Math.PI*2);
        ctx.strokeStyle=`rgba(34,83,73,${(1-life)*.16})`;ctx.lineWidth=2.2;ctx.stroke();
        ctx.beginPath();ctx.ellipse(wake.x*width,wake.y*height-1,r,r*.32,0,0,Math.PI*2);
        ctx.strokeStyle=`rgba(249,255,233,${(1-life)*.65})`;ctx.lineWidth=.9;ctx.stroke();
      }
      if(life<.13) { ctx.beginPath();ctx.ellipse(wake.x*width,wake.y*height,1.5,4*(1-life/.13),0,0,Math.PI*2);ctx.fillStyle='rgba(255,255,245,.65)';ctx.fill(); }
    }
  }
  function tick(now) {
    frame=null;
    if(document.hidden || motion.matches) return;
    if(now-last>=42) { draw(Math.min(80,now-last || 42)); last=now; }
    frame=requestAnimationFrame(tick);
  }
  function start() { if(frame==null && !document.hidden && !motion.matches) { last=performance.now();frame=requestAnimationFrame(tick); } }
  function stop() { if(frame!=null) cancelAnimationFrame(frame);frame=null; }
  root.addEventListener('resize',resize);
  document.addEventListener('pointermove',event=>{
    if(motion.matches || event.pointerType==='touch') return;
    const x=event.clientX/width,y=event.clientY/height;
    const distance=Math.hypot((x-pointer.x)*width,(y-pointer.y)*height);
    pointer={x,y}; const now=performance.now();
    if(distance>6 && now-lastWake>170) { impact(x,y,1.3);lastWake=now; }
  },{passive:true});
  document.addEventListener('visibilitychange',()=>document.hidden?stop():start());
  motion.addEventListener('change',()=>{stop();wakes.length=0;if(motion.matches) draw(0);else start();});
  root.addEventListener('pagehide',stop);
  resize();
})(globalThis);
