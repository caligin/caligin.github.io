.PHONY: serve

serve:
	docker run -v $$PWD:/srv/jekyll -v $$PWD/_site:/srv/jekyll/_site --mount 'source=caligin-gem-cache,target=/usr/local/bundle' -p 4000:4000 --rm jekyll/builder:latest /bin/bash -c "chmod 777 /srv/jekyll && jekyll serve --drafts --force_polling"
