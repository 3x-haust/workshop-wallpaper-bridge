// Compatibility implementation from the public SceneScript interface, not engine source.
// Runs only inside the disposable script worker; no native objects are exposed to JS.
(function () {
    'use strict';
    const axes = ['x', 'y', 'z', 'w'];
    class Vector {
        constructor(n, args) {
            Object.defineProperty(this, '_n', {value:n});
            let values = args;
            if (args.length === 1) {
                const v = args[0];
                values = typeof v === 'string' ? v.trim().split(/\s+/).map(Number)
                    : typeof v === 'number' ? Array(n).fill(v)
                    : axes.slice(0,n).map(k => v?.[k] ?? 0);
            }
            axes.slice(0,n).forEach((k,i) => this[k] = Number(values[i] ?? 0));
        }
        map(f) { return new this.constructor(...axes.slice(0,this._n).map((k,i)=>f(this[k],k,i))); }
        zip(v,f) { return this.map((a,k)=>f(a, typeof v === 'number' ? v : (v[k] ?? 0))); }
        copy() { return this.map(a=>a); }
        add(v) { return this.zip(v,(a,b)=>a+b); }
        subtract(v) { return this.zip(v,(a,b)=>a-b); }
        multiply(v) { return this.zip(v,(a,b)=>a*b); }
        divide(v) { return this.zip(v,(a,b)=>a/b); }
        dot(v) { return axes.slice(0,this._n).reduce((s,k)=>s+this[k]*(v[k]??0),0); }
        lengthSqr() { return this.dot(this); }
        length() { return Math.sqrt(this.lengthSqr()); }
        normalize() { const l=this.length(); return l ? this.divide(l) : this.copy(); }
        distanceSqr(v) { return this.subtract(v).lengthSqr(); }
        distance(v) { return Math.sqrt(this.distanceSqr(v)); }
        equals(v) { return this.distanceSqr(v) < 1e-10; }
        isFinite() { return axes.slice(0,this._n).every(k=>Number.isFinite(this[k])); }
        negate() { return this.multiply(-1); }
        reflect(n) { return this.subtract(n.multiply(2*this.dot(n))); }
        project(v) { return v.multiply(this.dot(v)/v.lengthSqr()); }
        mix(v,t) { return this.add(v.subtract(this).multiply(t)); }
        min(v) { return this.zip(v,Math.min); }
        max(v) { return this.zip(v,Math.max); }
        clamp(a,b) { return this.max(a).min(b); }
        abs() { return this.map(Math.abs); }
        sign() { return this.map(Math.sign); }
        round() { return this.map(v=>Math.floor(v+0.5)); }
        floor() { return this.map(Math.floor); }
        ceil() { return this.map(Math.ceil); }
        fract() { return this.map(v=>v-Math.floor(v)); }
        mod(v) { return this.zip(v,(a,b)=>a-b*Math.floor(a/b)); }
        step(v) { return this.zip(v,(a,b)=>a<b?0:1); }
        smoothStep(a,b) { return this.map((v,k)=>WEMath.smoothStep(typeof a==='number'?a:a[k],typeof b==='number'?b:b[k],v)); }
        toString() { return axes.slice(0,this._n).map(k=>this[k]).join(' '); }
        toJSON() { return axes.slice(0,this._n).map(k=>this[k]); }
    }
    class Vec2 extends Vector {
        constructor(...args) { super(2,args); }
        perpendicular() { return new Vec2(-this.y,this.x); }
        angle() { return Math.atan2(this.y,this.x)*180/Math.PI; }
        angleBetween(v) { return Math.atan2(this.x*v.y-this.y*v.x,this.dot(v))*180/Math.PI; }
        rotate(deg) { const r=deg*Math.PI/180,c=Math.cos(r),s=Math.sin(r); return new Vec2(this.x*c-this.y*s,this.x*s+this.y*c); }
    }
    class Vec3 extends Vector {
        constructor(...args) { super(3,args); }
        cross(v) { return new Vec3(this.y*v.z-this.z*v.y,this.z*v.x-this.x*v.z,this.x*v.y-this.y*v.x); }
        angleBetween(v) { return Math.acos(Math.max(-1,Math.min(1,this.dot(v)/(this.length()*v.length()))))*180/Math.PI; }
        refract(n,eta) { const d=n.dot(this),k=1-eta*eta*(1-d*d); return k<0?new Vec3():this.multiply(eta).subtract(n.multiply(eta*d+Math.sqrt(k))); }
        static fromSpherical(r,theta,phi) { theta*=Math.PI/180;phi*=Math.PI/180;return new Vec3(r*Math.sin(theta)*Math.sin(phi),r*Math.cos(theta),r*Math.sin(theta)*Math.cos(phi)); }
        toSpherical() { const r=this.length();return new Vec3(r,r?Math.acos(this.y/r)*180/Math.PI:0,Math.atan2(this.x,this.z)*180/Math.PI); }
    }
    class Vec4 extends Vector { constructor(...args) { super(4,args); } }
    const WEMath = Object.freeze({deg2rad:Math.PI/180,rad2deg:180/Math.PI,
        mix:(a,b,t)=>a+(b-a)*t,
        smoothStep:(a,b,v)=>{const t=Math.max(0,Math.min(1,(v-a)/(b-a)));return t*t*(3-2*t);}});
    const WEVector = Object.freeze({angleVector2:a=>new Vec2(1,0).rotate(a),vectorAngle2:v=>v.angle()});
    const WEColor = Object.freeze({
        normalizeColor:v=>v.divide(255),expandColor:v=>v.multiply(255),
        hsv2rgb:v=>{const h=((v.x%1)+1)%1*6,c=v.z*v.y,x=c*(1-Math.abs(h%2-1)),m=v.z-c;
            const c3=[[c,x,0],[x,c,0],[0,c,x],[0,x,c],[x,0,c],[c,0,x]][Math.floor(h)];return new Vec3(...c3).add(m);},
        rgb2hsv:v=>{const max=Math.max(v.x,v.y,v.z),min=Math.min(v.x,v.y,v.z),d=max-min;
            let h=0;if(d)h=max===v.x?((v.y-v.z)/d)%6:max===v.y?(v.z-v.x)/d+2:(v.x-v.y)/d+4;
            return new Vec3(((h/6)%1+1)%1,max?d/max:0,max);}
    });
    const modules=Object.freeze({WEMath,WEVector,WEColor});
    class MediaPlaybackEvent { static PLAYBACK_STOPPED=0; static PLAYBACK_PLAYING=1; static PLAYBACK_PAUSED=2; }
    const hookNames=['mediaStatusChanged','mediaPropertiesChanged','mediaPlaybackChanged','mediaTimelineChanged','mediaThumbnailChanged','init','update','destroy','resizeScreen','applyUserProperties','applyGeneralSettings',
        'cursorEnter','cursorLeave','cursorMove','cursorDown','cursorUp','cursorClick'];
    const vectorProperties=new Set(['origin','scale','angles','color']);
    const writableProperties=new Set(['origin','scale','angles','alpha','visible','text','color','value']);
    let layers=[],objects=[],scripts=[],errors=[],shared={},frame={},canvas=new Vec2(1920,1080),userProperties={},previousMedia;
    const nativeDate=Date;
    function ClockDate(...args) {
        if (!new.target) return new nativeDate(frame.now).toString();
        return args.length ? new nativeDate(...args) : new nativeDate(frame.now);
    }
    ClockDate.now=()=>frame.now;ClockDate.parse=nativeDate.parse;ClockDate.UTC=nativeDate.UTC;ClockDate.prototype=nativeDate.prototype;
    function convert(property,value) { return vectorProperties.has(property) && Array.isArray(value)?new Vec3(...value):value; }
    function valid(property,value) {
        if(vectorProperties.has(property)) return value instanceof Vec3 && value.isFinite() && axes.slice(0,3).every(k=>Math.abs(value[k])<=1e7);
        if(property==='alpha'||property==='value') return typeof value==='number' && Number.isFinite(value);
        if(property==='visible') return typeof value==='boolean';
        return property==='text' && typeof value==='string' && value.length<=16384;
    }
    function error(s,e) { if(errors.length<64)errors.push({layer:s.id,property:s.property,message:String(e).slice(0,512)});s.failed=true; }
    function getLayer(name) {
        if(typeof name==='number')return layers[name]?.api;
        return (layers.find(l=>l.name===name)||layers.find(l=>String(l.id)===String(name)))?.api;
    }
    const thisScene={getLayer,getLayerByID:id=>layers.find(l=>String(l.id)===String(id))?.api,
        getLayerCount:()=>layers.length,enumerateLayers:()=>layers.map(l=>l.api)};
    function makeLayer(raw) {
        const l={id:raw.id,name:raw.name,size:raw.size,values:{},dirty:new Set()};
        Object.entries(raw.values).forEach(([k,v])=>l.values[k]=convert(k,v));
        l.api=new Proxy({name:l.name,maxwidth:Number.isFinite(raw.maxwidth)?raw.maxwidth:(raw.textMetrics?.maximumWidth||l.size?.[0]||0)}, {
            get:(target,key)=>key==='size'?new Vec2(...(__wwbMeasureText(l.id,l.values.text||'')||l.size)):
                key==='getAnimation'?()=>{if(!l.getAnimation)throw new Error('No bound animation');return l.getAnimation();}:
                key in l.values?(l.values[key] instanceof Vector?l.values[key].copy():l.values[key]):target[key],
            set:(target,key,value)=>{
                if(!writableProperties.has(key))throw new Error('Unsupported layer property: '+String(key));
                if(!valid(key,value))throw new Error('Invalid layer value: '+String(key));
                l.values[key]=value instanceof Vector?value.copy():value;l.dirty.add(key);return true;
            }
        });
        if(raw.animation) {
            const a=raw.animation, keys=(a.c0||[]).slice(0,4096).filter(k=>Number.isFinite(k.frame)&&Number.isFinite(k.value)).sort((a,b)=>a.frame-b.frame);
            const options=a.options||{}, fps=Math.max(1,Math.min(240,options.fps||30));
            const length=Math.max(1,options.length||keys[keys.length-1]?.frame||1);
            let started=frame.time, offset=0, playing=!options.startpaused;
            function sample() {
                if(!keys.length)return;
                let position=(playing?frame.time-started:offset)*fps;
                if(options.mode==='loop')position%=length;
                else if(options.mode==='mirror'){position%=length*2;if(position>length)position=length*2-position;}
                else if(position>=length){position=length;playing=false;offset=length/fps;}
                let value=keys[0].value;
                if(position>=keys[keys.length-1].frame)value=keys[keys.length-1].value;
                else for(let i=1;i<keys.length;i++)if(position<=keys[i].frame){
                    const left=keys[i-1],right=keys[i],width=right.frame-left.frame;
                    let t=width>0?(position-left.frame)/width:0;
                    if(left.front?.enabled||right.back?.enabled){
                        const x1=left.frame+(left.front?.enabled?left.front.x:width/3),x2=right.frame+(right.back?.enabled?right.back.x:-width/3);
                        const y1=left.value+(left.front?.enabled?left.front.y:(right.value-left.value)/3),y2=right.value+(right.back?.enabled?right.back.y:(left.value-right.value)/3);
                        const bez=(a,b,c,d,t)=>a*(1-t)**3+3*b*(1-t)**2*t+3*c*(1-t)*t*t+d*t*t*t;
                        let lo=0,hi=1;for(let j=0;j<24;j++){t=(lo+hi)/2;if(bez(left.frame,x1,x2,right.frame,t)<position)lo=t;else hi=t;}
                        value=bez(left.value,y1,y2,right.value,t);
                    }else value=left.value+(right.value-left.value)*t;
                    break;
                }
                if(Number.isFinite(value))l.api.value=value;
            }
            const api={play:()=>{started=frame.time-offset;playing=true;sample();},stop:()=>{playing=false;offset=0;sample();},
                pause:()=>{if(playing)offset=frame.time-started;playing=false;},isPlaying:()=>playing};
            l.animate=()=>{if(playing)sample();};
            l.getAnimation=()=>api;
        }
        return l;
    }
    // Lex strings and comments before rewriting module syntax. No textual replacement inside copy.
    function tokens(source) {
        const result=[];let i=0;
        while(i<source.length) {
            const start=i,c=source[i];
            if(/\s/.test(c)){i++;continue;}
            if(source.slice(i,i+2)==='//'){i=source.indexOf('\n',i+2);if(i<0)break;continue;}
            if(source.slice(i,i+2)==='/*'){const end=source.indexOf('*/',i+2);if(end<0)throw new Error('Unclosed comment');i=end+2;continue;}
            if(c==='"'||c==="'"||c==='`'){
                i++;while(i<source.length){if(source[i]==='\\'){i+=2;continue;}if(source[i++]===c)break;}
                result.push({value:source.slice(start,i),start,end:i,string:true});continue;
            }
            if(/[a-zA-Z_$]/.test(c)){i++;while(i<source.length&&/[\w$]/.test(source[i]))i++;}
            else i++;
            result.push({value:source.slice(start,i),start,end:i});
        }
        return result;
    }
    function normalize(source) {
        const ts=tokens(source),edits=[];let depth=0;
        for(let i=0;i<ts.length;i++) {
            if(ts[i].string)continue;
            if(ts[i].value==='}')depth--;
            if(ts[i].value==='{')depth++;
            if(depth!==0 || ts[i-1]?.value==='.')continue;
            if(ts[i].value==='export') {
                const next=ts[i+1];
                if(!next||!['function','const','let','var','default'].includes(next.value))throw new Error('Unsupported export syntax');
                edits.push({start:ts[i].start,end:next.value==='default'?next.end:ts[i].end,text:''});
            }
            if(ts[i].value==='import') {
                const start=i;let end=i+1;
                while(end<ts.length&&!ts[end].string)end++;
                if(end===ts.length)throw new Error('Unsupported import syntax');
                const moduleName=ts[end].value.slice(1,-1);
                if(!Object.hasOwn(modules,moduleName))throw new Error('Unsupported module: '+moduleName);
                const body=source.slice(ts[i+1].start,ts[end].start).trim();let replacement;
                if(/^\*\s+as\s+[\w$]+\s+from$/.test(body))replacement='const '+body.split(/\s+/)[2]+' = __modules.'+moduleName+';';
                else if(/^\{[\w$\s,]+\}\s*from$/.test(body)) {
                    const names=body.slice(1,body.indexOf('}')).replace(/\bas\b/g,':');
                    replacement='const {'+names+'} = __modules.'+moduleName+';';
                } else throw new Error('Unsupported import syntax');
                if(ts[end+1]?.value===';')end++;
                edits.push({start:ts[start].start,end:ts[end].end,text:replacement});i=end;
            }
        }
        for(const edit of edits.reverse())source=source.slice(0,edit.start)+edit.text+source.slice(edit.end);
        return source;
    }
    function compile(raw,layer,target=layer) {
        const s={id:target.id,property:raw.property,layer,target,failed:false,buffers:[],timers:[],inside:false,pressed:false};
        const engine={AUDIO_RESOLUTION_16:16,AUDIO_RESOLUTION_32:32,AUDIO_RESOLUTION_64:64,
            isRunningInEditor:()=>false,isDesktopDevice:()=>true,isMobileDevice:()=>false,isWallpaper:()=>true,isScreensaver:()=>false,
            isPortrait:()=>frame.screen[1]>frame.screen[0],isLandscape:()=>frame.screen[0]>=frame.screen[1],
            registerAudioBuffers:n=>{if(![16,32,64].includes(n))throw new Error('Invalid audio resolution');
                const b={left:new Float32Array(n),right:new Float32Array(n),average:new Float32Array(n)};s.buffers.push(b);return b;},
            setTimeout:(fn,ms=0)=>timer(fn,ms,false),setInterval:(fn,ms=0)=>timer(fn,ms,true)};
        function timer(fn,ms,repeat) {
            if(typeof fn!=='function'||!Number.isFinite(ms)||s.timers.length>=128)throw new Error('Invalid or excessive timer');
            const t={fn,delay:Math.max(0,ms)/1000,next:frame.time+Math.max(0,ms)/1000,repeat,cancelled:false};
            s.timers.push(t);return ()=>{t.cancelled=true;};
        }
        for(const k of ['runtime','frametime','timeOfDay','screenResolution','canvasSize','userProperties'])Object.defineProperty(engine,k,{get:()=>
            ({runtime:frame.time,frametime:frame.frameTime,timeOfDay:frame.timeOfDay,screenResolution:new Vec2(...frame.screen),canvasSize:canvas.copy(),userProperties})[k]});
        const input={};
        Object.defineProperties(input,{cursorWorldPosition:{get:()=>new Vec3(...frame.cursor)},cursorScreenPosition:{get:()=>new Vec2(...frame.cursorScreen)},cursorLeftDown:{get:()=>!!frame.leftDown}});
        const createScriptProperties=()=>{
            const defaults={};const builder={finish:()=>Object.assign(defaults,raw.properties)};
            for(const name of ['Slider','Checkbox','Text','Combo','Color'])builder['add'+name]=(key,options)=>{if(key&&typeof key==='object'){options=key;key=options.name;}defaults[key]=options?.value;return builder;};
            return builder;
        };
        try {
            const source=normalize(raw.source);
            const hasProperties=tokens(source).some((t,i,all)=>['var','let','const'].includes(t.value)&&all[i+1]?.value==='scriptProperties');
            const factory=new Function('env',`'use strict';
                const {Vec2,Vec3,Vec4,engine,input,thisLayer,thisObject,thisScene,thisProperty,shared,Date,console,createScriptProperties,__modules,MediaPlaybackEvent}=env;
                ${hasProperties?'':'var scriptProperties=env.properties;'}
                ${source}
                if(typeof scriptProperties==='object' && scriptProperties!==null)Object.assign(scriptProperties,env.properties);
                return {${hookNames.map(k=>k+':typeof '+k+'==="function"?'+k+':undefined').join(',')}};`);
            s.hooks=factory({Vec2,Vec3,Vec4,engine,input,thisLayer:layer.api,thisObject:target.api,thisScene,thisProperty:target.api,shared,Date:ClockDate,
                console:{log:()=>{},warn:()=>{},error:()=>{}},MediaPlaybackEvent,createScriptProperties,__modules:modules,properties:raw.properties||{}});
        } catch(e) {error(s,e);}
        return s;
    }
    function invoke(s,name,arg,returnsValue=false) {
        if(s.failed||typeof s.hooks[name]!=='function')return;
        try {
            let value=s.hooks[name](arg instanceof Vector?arg.copy():arg);
            if(returnsValue && value!==undefined && value!==null) {
                if(vectorProperties.has(s.property) && typeof value==='number')value=new Vec3(value);
                s.target.api[s.property]=value;
            }
        } catch(e) {error(s,e);}
    }
    function feedAudio(s) {
        for(const b of s.buffers)for(let i=0;i<b.left.length;i++) {
            const start=Math.floor(i*64/b.left.length),end=Math.floor((i+1)*64/b.left.length);let l=0,r=0;
            for(let j=start;j<end;j++){l+=frame.audioLeft[j]||0;r+=frame.audioRight[j]||0;}
            b.left[i]=l/(end-start);b.right[i]=r/(end-start);b.average[i]=(b.left[i]+b.right[i])/2;
        }
    }
    function cursor(s) {
        if(Array.isArray(frame.cursorEvents) && frame.cursorEvents.length) {
            for(const event of frame.cursorEvents.slice(0,64))cursorAt(s,Object.assign({},frame,event,{cursorMoved:false}));
            cursorAt(s,Object.assign({},frame,{down:false,up:false}));
        } else cursorAt(s,frame);
    }
    function cursorAt(s,state) {
        const v=s.layer.values,world=new Vec3(...state.cursor),delta=world.subtract(v.origin),angle=-v.angles.z*Math.PI/180;
        const local=new Vec3((delta.x*Math.cos(angle)-delta.y*Math.sin(angle))/v.scale.x,(delta.x*Math.sin(angle)+delta.y*Math.cos(angle))/v.scale.y,0);
        const inside=!!state.cursorInside && v.visible && Math.abs(local.x)<=s.layer.size[0]/2 && Math.abs(local.y)<=s.layer.size[1]/2;
        const event={worldPosition:world,localPosition:local};
        if(inside!==s.inside)invoke(s,inside?'cursorEnter':'cursorLeave',event);
        if(state.cursorMoved && inside)invoke(s,'cursorMove',event);
        if(state.down && inside){s.pressed=true;invoke(s,'cursorDown',event);}
        if(state.up){if(inside){invoke(s,'cursorUp',event);if(s.pressed)invoke(s,'cursorClick',event);}s.pressed=false;}
        s.inside=inside;
    }
    function setFrame(f) {
        const previous=frame;
        frame=Object.assign({time:0,frameTime:0,now:nativeDate.now(),screen:[1920,1080],cursor:[0,0,0],cursorScreen:[0,0],cursorInside:false,leftDown:false,audioLeft:[],audioRight:[]},f);
        frame.down=!!frame.leftDown&&!previous.leftDown;frame.up=!frame.leftDown&&!!previous.leftDown;
        frame.cursorMoved=JSON.stringify(previous.cursor)!==JSON.stringify(frame.cursor);
        const d=new nativeDate(frame.now);frame.timeOfDay=(d.getHours()*3600+d.getMinutes()*60+d.getSeconds()+d.getMilliseconds()/1000)/86400;
    }
    function snapshot(list=layers) { return list.map(l=>JSON.stringify(l.values)); }
    function mediaEvents() {
        const m=Object.assign({enabled:false,state:0,title:'',artist:'',albumTitle:'',albumArtist:'',position:0,duration:0,
            hasThumbnail:false,artworkRevision:''},frame.media||{});
        const old=previousMedia;
        const changed=keys=>!old||keys.some(k=>m[k]!==old[k]);
        for(const s of scripts) {
            if(changed(['enabled']))invoke(s,'mediaStatusChanged',{enabled:m.enabled});
            if(changed(['title','artist','albumTitle','albumArtist']))invoke(s,'mediaPropertiesChanged',
                {title:m.title,artist:m.artist,albumTitle:m.albumTitle,albumArtist:m.albumArtist,contentType:'music'});
            if(changed(['hasThumbnail','artworkRevision']))invoke(s,'mediaThumbnailChanged',{hasThumbnail:m.hasThumbnail});
            if(changed(['state']))invoke(s,'mediaPlaybackChanged',{state:m.state});
            if(changed(['position','duration']))invoke(s,'mediaTimelineChanged',{position:m.position,duration:m.duration});
        }
        previousMedia=m;
    }
    function changes(before,list=layers) {
        return list.map((l,i)=>{
            const old=JSON.parse(before[i]),values={};
            for(const [key,value] of Object.entries(l.values)) {
                if(!valid(key,value)){l.values[key]=convert(key,old[key]);continue;}
                if(l.dirty.has(key)||JSON.stringify(value)!==JSON.stringify(old[key]))values[key]=value;
            }
            l.dirty.clear();return {id:l.id,values};
        }).filter(l=>Object.keys(l.values).length);
    }
    return function request(json) {
        errors=[];
        const request=JSON.parse(json);setFrame(request.frame||{});
        if(request.configure) {
            scripts.forEach(s=>invoke(s,'destroy'));
            const c=request.configure;shared={};previousMedia=undefined;canvas=new Vec2(...c.canvasSize);userProperties=c.userProperties||{};
            layers=c.layers.map(makeLayer);
            objects=(c.objects||[]).slice(0,128).map(makeLayer);
            scripts=[];
            c.layers.forEach((l,i)=>l.scripts.forEach(raw=>scripts.push(compile(raw,layers[i]))));
            (c.objects||[]).slice(0,128).forEach((o,i)=>{
                const parent=layers.find(l=>l.id===o.layerID);
                if(parent)o.scripts.forEach(raw=>scripts.push(compile(raw,parent,objects[i])));
            });
            const before=snapshot(),objectBefore=snapshot(objects);
            for(const s of scripts){feedAudio(s);invoke(s,'init',s.target.values[s.property],true);}
            for(const s of scripts){invoke(s,'applyGeneralSettings',{language:c.language||'en'});invoke(s,'applyUserProperties',userProperties);cursor(s);}
            mediaEvents();
            return JSON.stringify({layers:changes(before),objects:changes(objectBefore,objects),errors});
        }
        const before=snapshot(),objectBefore=snapshot(objects);
        mediaEvents();
        objects.forEach(o=>o.animate?.());
        for(const s of scripts) {
            if(s.failed)continue;
            feedAudio(s);
            if(request.resized)invoke(s,'resizeScreen',new Vec2(...frame.screen));
            cursor(s);
            for(const t of s.timers.slice())if(!t.cancelled&&t.next<=frame.time) {
                t.next=frame.time+t.delay;if(!t.repeat)t.cancelled=true;
                try{t.fn();}catch(e){error(s,e);break;}
            }
            s.timers=s.timers.filter(t=>!t.cancelled);
            invoke(s,'update',s.target.values[s.property],true);
        }
        return JSON.stringify({layers:changes(before),objects:changes(objectBefore,objects),errors});
    };
})()
