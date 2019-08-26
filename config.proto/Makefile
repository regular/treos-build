iso:
	bash -c 'ssb-archiso | tee >(grep "New .* password is" > passwords) 2>&1 | tee log'

clean:
	sudo rm -rf root/ build/

.PHONEY: iso clean
