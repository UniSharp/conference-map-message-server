all: install compile run

install:
	npm install

compile:
	./node_modules/.bin/lsc -c server.ls

run:
	node server.js
