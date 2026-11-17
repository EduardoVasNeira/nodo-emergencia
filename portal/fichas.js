// Fichas "qué hacer" (portal/fichas/<PAIS>.json): las dibuja /ficha y el buscador.
// Todo se arma con textContent: el contenido nunca se interpreta como HTML.
"use strict";

async function cargarFichas() {
	const c = await fetch("/config.json").then(r => r.json()).catch(() => ({}));
	const r = await fetch("/fichas/" + (c.pais || "CL") + ".json");
	if (!r.ok) throw new Error("sin fichas");
	return (await r.json()).fichas || [];
}

function nodo(tag, clase, texto) {
	const e = document.createElement(tag);
	if (clase) e.className = clase;
	if (texto != null) e.textContent = texto;
	return e;
}

// Ícono de iconos.svg (texto fijo del portal, no viene de las fichas).
function icono(nombre) {
	const ns = "http://www.w3.org/2000/svg";
	const s = document.createElementNS(ns, "svg");
	s.setAttribute("class", "icono-svg"); s.setAttribute("aria-hidden", "true");
	const u = document.createElementNS(ns, "use");
	u.setAttribute("href", "/iconos.svg#i-" + nombre);
	s.appendChild(u);
	return s;
}

function titulo3(nombreIcono, texto) {
	const h = nodo("h3");
	h.append(icono(nombreIcono), texto);
	return h;
}

function lista(tag, items) {
	const l = document.createElement(tag);
	for (const t of items || []) l.appendChild(nodo("li", null, t));
	return l;
}

// "A quién llamar": el texto completo y un botón por cada número que aparezca
// (131, *4141, 600 360 7777, +56 2 2635 3800). Un "20 minutos" no es un número de teléfono.
function bloqueLlamar(texto) {
	const caja = nodo("div", "a-quien");
	caja.appendChild(nodo("p", null, "A quién llamar: " + texto));
	for (const m of texto.match(/\*\d{4}|\+?\d[\d ]{6,}\d|\b1\d\d\b/g) || []) {
		const a = nodo("a", "llamar");
		a.append(icono("phone"), m);
		a.href = "tel:" + m.replace(/ /g, "");
		caja.appendChild(a);
	}
	return caja;
}

function dibujarFicha(f) {
	const art = nodo("article", "ficha");
	art.id = f.id;
	art.appendChild(nodo("div", "etiqueta", "Qué hacer"));
	art.appendChild(nodo("h2", null, f.titulo));
	if (f.urgente_si && f.urgente_si.length) {
		const u = nodo("div", "urgente");
		u.appendChild(titulo3("triangle-alert", "Llama o ve a urgencia de inmediato si:"));
		u.appendChild(lista("ul", f.urgente_si));
		art.appendChild(u);
	}
	art.appendChild(lista("ol", f.pasos));
	if (f.no_hacer && f.no_hacer.length) {
		const n = nodo("div", "no-hacer");
		n.appendChild(titulo3("ban", "No hagas esto:"));
		n.appendChild(lista("ul", f.no_hacer));
		art.appendChild(n);
	}
	if (f.llamar) art.appendChild(bloqueLlamar(f.llamar));
	if (f.nota) art.appendChild(nodo("p", "fuente", "Nota: " + f.nota));
	if (f.fuentes && f.fuentes.length) {
		const p = nodo("p", "fuente", "Fuente: ");
		f.fuentes.forEach((x, i) => {
			if (i) p.append(" · ");
			p.append(x.nombre + (x.pais && x.pais !== "CL" ? " (" + x.pais + ")" : ""));
		});
		art.appendChild(p);
	}
	return art;
}
