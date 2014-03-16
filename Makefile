all: install compile run

install:
	npm install

compile:
	lsc -c server.ls

run:
	node server.js
