.SHELL: bash

.PHONY: all update-submodule
all:  $(CURDIR)/.pyyaml_touch

update-submodule:
	GIT_ALLOW_PROTOCOL='file' git submodule update --recursive

$(CURDIR)/.pyyaml_touch: 
	pip3 install --user pyyaml
	touch $@
