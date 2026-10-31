// Fundo preto puro e a marca em deslocamento lento, para não marcar a tela OLED.
const logo = document.getElementById("logo");
function move() {
  logo.style.left = Math.random() * (innerWidth - logo.offsetWidth) + "px";
  logo.style.top = Math.random() * (innerHeight - logo.offsetHeight) + "px";
}
logo.style.left = innerWidth / 3 + "px";
logo.style.top = innerHeight / 2 + "px";
requestAnimationFrame(move);
setInterval(move, 60000);
